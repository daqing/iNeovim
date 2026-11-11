#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/iNeovim.xcodeproj"
EXPORT_OPTIONS="$ROOT_DIR/Config/ExportOptions.plist"
SCHEME="iNeovim"
APP_NAME="iNeovim"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-iNeovim-notary}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/publish}"
NOTARIZE=1
UPLOAD=0

usage() {
    cat <<'EOF'
Usage: Scripts/publish.sh [--skip-notarize] [--upload]

Builds a Release archive, exports it with the project's Developer ID signing
configuration, notarizes it, staples the ticket, and verifies Gatekeeper
acceptance. Creates a ZIP and a drag-to-Applications DMG in
build/publish/<timestamp>-<pid>/.

A full release requires an app-specific password stored once with:
  xcrun notarytool store-credentials "iNeovim-notary" \
    --apple-id "<apple-id>" --team-id "S39RD89QY9" \
    --password "<app-specific-password>"

Options:
  --skip-notarize  Build and verify the Developer ID signatures only. The
                   resulting ZIP and DMG are marked unnotarized and are not
                   suitable for normal Internet distribution.
  --upload         Publish the ZIP and DMG to the GitHub release for tag
                   v<version>, creating a public release when none exists.
                   Requires the GitHub CLI (authenticated), a clean working
                   tree, and that annotated tag already pushed to origin.
  -h, --help       Show this help.

Environment:
  NOTARY_KEYCHAIN_PROFILE  Keychain profile name (default: iNeovim-notary).
  SIGN_IDENTITY           Full Developer ID Application certificate name.
                          Auto-detected for the configured team by default.
  BUILD_ROOT              Artifact parent directory (default: build/publish).
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'publish: %s\n' "$*" >&2
    exit 1
}

notarize() {
    local submission_path="$1"
    local result_path="$2"
    local log_path="$3"
    local submit_status=0
    local notary_status=""
    local submission_id=""

    log "Submitting ${submission_path##*/} with keychain profile $NOTARY_KEYCHAIN_PROFILE"
    xcrun notarytool submit "$submission_path" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait \
        --output-format json >"$result_path" || submit_status=$?

    if [[ -s "$result_path" ]]; then
        notary_status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"
        submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
    fi

    if [[ "$notary_status" != "Accepted" ]]; then
        if [[ -n "$submission_id" ]]; then
            if xcrun notarytool log "$submission_id" \
                --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
                "$log_path"; then
                printf 'Notarization log: %s\n' "$log_path" >&2
            fi
        fi
        fail "notarization failed for $submission_path (command status $submit_status, Apple status ${notary_status:-unknown}); see $result_path and docs/RELEASE.md"
    fi

    printf 'Notarization accepted for %s: %s\n' "${submission_path##*/}" "$submission_id"
}

create_installer_dmg() {
    local dmg_path="$1"
    local staging_path="$2"

    log "Creating the drag-to-Applications DMG"
    mkdir -p "$staging_path"
    ditto "$APP_PATH" "$staging_path/$APP_NAME.app"
    ln -s /Applications "$staging_path/Applications"
    diskutil image create from \
        --format UDZO \
        --volumeName "$APP_NAME" \
        "$staging_path" \
        "$dmg_path"
    hdiutil verify "$dmg_path"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path"
}

check_upload_prerequisites() {
    local tag="v$VERSION"
    local tag_commit=""
    local head_commit=""
    local remote_commit=""

    command -v gh >/dev/null 2>&1 || fail "--upload requires the GitHub CLI (brew install gh)"
    gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run: gh auth login"
    git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "--upload must run inside the git checkout"

    REPO="$(cd "$ROOT_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner)" \
        || fail "could not resolve the GitHub repository from the origin remote"

    git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
        || fail "tag $tag does not exist. Create and push it first:
  git tag -a $tag -m \"$APP_NAME $VERSION\"
  git push origin $tag"

    [[ "$(git -C "$ROOT_DIR" cat-file -t "refs/tags/$tag")" == "tag" ]] \
        || fail "tag $tag is a lightweight tag; recreate it as an annotated tag"

    tag_commit="$(git -C "$ROOT_DIR" rev-parse "refs/tags/$tag^{commit}")"
    head_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    [[ "$tag_commit" == "$head_commit" ]] \
        || fail "tag $tag points at ${tag_commit:0:7} but HEAD is ${head_commit:0:7}; release builds must come from the tagged commit"

    [[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] \
        || fail "the working tree has uncommitted changes; commit them so the release matches $tag"

    remote_commit="$(git -C "$ROOT_DIR" ls-remote origin "refs/tags/$tag^{}" | awk 'NR == 1 { print $1 }')" \
        || fail "could not read tag $tag from origin"
    [[ -n "$remote_commit" ]] || fail "tag $tag is not on origin; run: git push origin $tag"
    [[ "$remote_commit" == "$head_commit" ]] \
        || fail "origin's tag $tag points at ${remote_commit:0:7} but HEAD is ${head_commit:0:7}; push the tag or rebuild from the tagged commit"
}

upload_release() {
    local tag="v$VERSION"
    local draft=""
    local asset=""

    if gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
        log "Uploading assets to the existing release $tag"
        gh release upload "$tag" "$RELEASE_ZIP" "$RELEASE_DMG" -R "$REPO" --clobber
        draft="$(gh release view "$tag" -R "$REPO" --json isDraft -q .isDraft)"
        if [[ "$draft" == "true" ]]; then
            log "Publishing the draft release $tag"
            gh release edit "$tag" -R "$REPO" --draft=false
        fi
    else
        log "Publishing the GitHub release $tag"
        gh release create "$tag" "$RELEASE_ZIP" "$RELEASE_DMG" -R "$REPO" \
            --verify-tag \
            --title "$APP_NAME $VERSION" \
            --generate-notes
    fi

    for asset in "$(basename "$RELEASE_ZIP")" "$(basename "$RELEASE_DMG")"; do
        gh release view "$tag" -R "$REPO" --json assets -q '.assets[].name' | grep -qx "$asset" \
            || fail "asset $asset is missing from release $tag"
    done
    printf 'Release:      %s\n' "$(gh release view "$tag" -R "$REPO" --json url -q .url)"
}

while (($# > 0)); do
    case "$1" in
        --skip-notarize)
            NOTARIZE=0
            ;;
        --upload)
            UPLOAD=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
    shift
done

if ((UPLOAD == 1 && NOTARIZE == 0)); then
    fail "--upload requires notarization; drop --skip-notarize"
fi

for tool in xcodebuild xcrun security codesign spctl ditto plutil hdiutil diskutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

[[ -d "$PROJECT_PATH" ]] || fail "project not found: $PROJECT_PATH"
[[ -f "$EXPORT_OPTIONS" ]] || fail "export options not found: $EXPORT_OPTIONS"
xcodebuild -version >/dev/null 2>&1 || fail "a full Xcode installation is required"

TEAM_ID="$(plutil -extract teamID raw -o - "$EXPORT_OPTIONS")" || fail "teamID is missing from $EXPORT_OPTIONS"
[[ -n "$TEAM_ID" ]] || fail "teamID is empty in $EXPORT_OPTIONS"

IDENTITIES="$(security find-identity -v -p codesigning)" || fail "could not read code-signing identities"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    while IFS= read -r line; do
        identity="${line#*\"}"
        identity="${identity%%\"*}"
        if [[ "$identity" == "Developer ID Application:"* && "$identity" == *"($TEAM_ID)" ]]; then
            SIGN_IDENTITY="$identity"
            break
        fi
    done <<< "$IDENTITIES"
fi

[[ -n "$SIGN_IDENTITY" ]] || fail "no valid Developer ID Application certificate found for team $TEAM_ID"
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || fail "SIGN_IDENTITY must name a Developer ID Application certificate"
[[ "$IDENTITIES" == *"\"$SIGN_IDENTITY\""* ]] || fail "signing identity is not valid in the local keychain: $SIGN_IDENTITY"

RUN_DIR="$BUILD_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
ARCHIVE_PATH="$RUN_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$RUN_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
mkdir -p "$RUN_DIR"

printf 'Project:          %s\n' "$PROJECT_PATH"
printf 'Signing identity: %s\n' "$SIGN_IDENTITY"
printf 'Artifacts:        %s\n' "$RUN_DIR"

log "Archiving $SCHEME (Release)"
xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic

log "Exporting the Developer ID build"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

[[ -d "$APP_PATH" ]] || fail "exported app not found: $APP_PATH"
[[ -d "$APP_PATH/Contents/Frameworks/GhosttySupport.framework" ]] || fail "GhosttySupport.framework is missing from the exported app"

log "Verifying the Developer ID signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
printf '%s\n' "$SIGNING_DETAILS"
[[ "$SIGNING_DETAILS" == *"Authority=Developer ID Application:"* ]] || fail "the exported app is not signed with a Developer ID Application certificate"
[[ "$SIGNING_DETAILS" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "the exported app has the wrong team identifier"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")" || fail "could not read CFBundleShortVersionString"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")" || fail "could not read CFBundleVersion"
ARTIFACT_BASE="$RUN_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER"
SUBMISSION_ZIP="$ARTIFACT_BASE-submission.zip"
DMG_STAGING="$RUN_DIR/dmg-root"

if ((UPLOAD == 1)); then
    check_upload_prerequisites
fi

if ((NOTARIZE == 0)); then
    RELEASE_ZIP="$ARTIFACT_BASE-unnotarized.zip"
    RELEASE_DMG="$ARTIFACT_BASE-unnotarized.dmg"
    log "Creating the unnotarized ZIP"
    ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"
    create_installer_dmg "$RELEASE_DMG" "$DMG_STAGING"
    printf '\nSigned app (not notarized): %s\n' "$APP_PATH"
    printf 'Signed ZIP (not notarized): %s\n' "$RELEASE_ZIP"
    printf 'Signed DMG (not notarized): %s\n' "$RELEASE_DMG"
    printf 'Do not use this output for normal Internet distribution.\n'
    exit 0
fi

RELEASE_ZIP="$ARTIFACT_BASE.zip"
RELEASE_DMG="$ARTIFACT_BASE.dmg"

log "Creating the app notarization submission"
ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
notarize "$SUBMISSION_ZIP" "$RUN_DIR/app-notarization.json" "$RUN_DIR/app-notary-log.json"

log "Stapling and validating the app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

log "Creating the distributable ZIP with the stapled app"
ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"

create_installer_dmg "$RELEASE_DMG" "$DMG_STAGING"
notarize "$RELEASE_DMG" "$RUN_DIR/dmg-notarization.json" "$RUN_DIR/dmg-notary-log.json"

log "Stapling and validating the DMG"
xcrun stapler staple "$RELEASE_DMG"
xcrun stapler validate "$RELEASE_DMG"
codesign --verify --verbose=2 "$RELEASE_DMG"

printf '\nRelease app:  %s\n' "$APP_PATH"
printf 'Release ZIP:  %s\n' "$RELEASE_ZIP"
printf 'Release DMG:  %s\n' "$RELEASE_DMG"
printf 'Version:      %s (%s)\n' "$VERSION" "$BUILD_NUMBER"

if ((UPLOAD == 1)); then
    upload_release
fi
