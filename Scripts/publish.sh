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

usage() {
    cat <<'EOF'
Usage: scripts/publish.sh [--skip-notarize]

Builds a Release archive, exports it with the project's Developer ID signing
configuration, notarizes it, staples the ticket, and verifies Gatekeeper
acceptance. Artifacts are written to build/publish/<timestamp>-<pid>/.

A full release requires an app-specific password stored once with:
  xcrun notarytool store-credentials "iNeovim-notary" \
    --apple-id "<apple-id>" --team-id "S39RD89QY9" \
    --password "<app-specific-password>"

Options:
  --skip-notarize  Build and verify the Developer ID signature only. The
                   resulting ZIP is marked unnotarized and is not suitable
                   for normal Internet distribution.
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

while (($# > 0)); do
    case "$1" in
        --skip-notarize)
            NOTARIZE=0
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

for tool in xcodebuild xcrun security codesign spctl ditto plutil; do
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

if ((NOTARIZE == 0)); then
    RELEASE_ZIP="$ARTIFACT_BASE-unnotarized.zip"
    log "Creating the unnotarized ZIP"
    ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"
    printf '\nSigned app (not notarized): %s\n' "$APP_PATH"
    printf 'Signed ZIP (not notarized): %s\n' "$RELEASE_ZIP"
    printf 'Do not use this output for normal Internet distribution.\n'
    exit 0
fi

log "Creating the notarization submission"
ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
NOTARY_RESULT="$RUN_DIR/notarization.json"
NOTARY_LOG="$RUN_DIR/notary-log.json"

log "Submitting to Apple notarization with keychain profile $NOTARY_KEYCHAIN_PROFILE"
SUBMIT_STATUS=0
xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait \
    --output-format json >"$NOTARY_RESULT" || SUBMIT_STATUS=$?

NOTARY_STATUS=""
SUBMISSION_ID=""
if [[ -s "$NOTARY_RESULT" ]]; then
    NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
    SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
fi

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    if [[ -n "$SUBMISSION_ID" ]]; then
        if xcrun notarytool log "$SUBMISSION_ID" \
            --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
            "$NOTARY_LOG"; then
            printf 'Notarization log: %s\n' "$NOTARY_LOG" >&2
        fi
    fi
    fail "notarization failed (command status $SUBMIT_STATUS, Apple status ${NOTARY_STATUS:-unknown}); see $NOTARY_RESULT and docs/RELEASE.md"
fi

printf 'Notarization accepted: %s\n' "$SUBMISSION_ID"

log "Stapling and validating the app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

RELEASE_ZIP="$ARTIFACT_BASE.zip"
log "Creating the distributable ZIP with the stapled app"
ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"

printf '\nRelease app: %s\n' "$APP_PATH"
printf 'Release ZIP: %s\n' "$RELEASE_ZIP"
printf 'Version:     %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
