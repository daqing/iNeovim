# Release

How to build, sign, notarize, and ship iNeovim. There is no CI; releases are
produced from an Xcode archive on a machine with the Developer ID certificate.

`Scripts/publish.sh` automates steps 2–6 (archive → export → notarize → staple
→ verify → optionally publish). The steps below are the equivalent manual
flow.

## Prerequisites

- Apple Developer Program membership and a **Developer ID Application**
  certificate in the login keychain.
- The Xcode project already has automatic signing with team `S39RD89QY9`
  (`DEVELOPMENT_TEAM`), the App Sandbox **disabled** (the embedded `nvim` needs
  host filesystem access), and `ENABLE_HARDENED_RUNTIME = YES`
  on Release (required for notarization).
- An app-specific password for notarization, stored once:

  ```
  xcrun notarytool store-credentials "iNeovim-notary" \
      --apple-id "<apple-id>" --team-id "S39RD89QY9" \
      --password "<app-specific-password>"
  ```

## 1. Bump the version

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in
`iNeovim.xcodeproj/project.pbxproj` (there is no standalone Info.plist).
Update both before archiving.

## 2. Archive

In Xcode: **Product ▸ Archive**. Or from the command line:

```
xcodebuild archive \
    -project iNeovim.xcodeproj \
    -scheme iNeovim \
    -configuration Release \
    -archivePath build/iNeovim.xcarchive
```

## 3. Export a Developer ID build

In Xcode Organizer: **Distribute App ▸ Developer ID**. Or:

```
xcodebuild -exportArchive \
    -archivePath build/iNeovim.xcarchive \
    -exportOptionsPlist Config/ExportOptions.plist \
    -exportPath build/export
```

`Config/ExportOptions.plist` selects `method = developer-id` with automatic
signing.

## 4. Notarize and staple

```
ditto -c -k --keepParent build/export/iNeovim.app build/iNeovim.zip
xcrun notarytool submit build/iNeovim.zip \
    --keychain-profile "iNeovim-notary" --wait
xcrun stapler staple build/export/iNeovim.app
```

## 5. Verify

```
spctl -a -vvv -t exec build/export/iNeovim.app   # expect "accepted, source=Notarized Developer ID"
xcrun stapler validate build/export/iNeovim.app
ls build/export/iNeovim.app/Contents/Frameworks   # expect GhosttySupport.framework
```

The last check guards the failure that build 2 shipped with: `GhosttySupport`
is a dynamic package product and nothing copies it into the bundle unless the
app target keeps its "Embed Frameworks" phase, so the app dies in dyld at
launch ("Library not loaded: @rpath/GhosttySupport.framework/…") even though
it ran fine from Xcode.

Optionally package a DMG for distribution:

```
hdiutil create -volname iNeovim -srcfolder build/export/iNeovim.app \
    -ov -format UDZO build/iNeovim.dmg
xcrun notarytool submit build/iNeovim.dmg --keychain-profile "iNeovim-notary" --wait
xcrun stapler staple build/iNeovim.dmg
```

## 6. Publish to GitHub

`Scripts/publish.sh --upload` runs the whole flow and then publishes the ZIP and
DMG to the GitHub release for tag `v<MARKETING_VERSION>`:

```
Scripts/publish.sh --upload
```

- The tag must already exist locally as an **annotated** tag, point at `HEAD`,
  and be pushed to `origin`; the working tree must be clean. The script fails
  with the exact commands to run instead of creating or pushing anything
  itself, so a release always matches its tag.
- The release is created public with `gh release create --generate-notes`.
  Running it again for an existing release overwrites the same-named assets
  (`gh release upload --clobber`) and publishes the release if it was a draft.
- Asset names carry the build number
  (`iNeovim-<version>-<build>.zip` / `.dmg`), so bumping
  `CURRENT_PROJECT_VERSION` keeps the previous build's files on the release
  alongside the new ones.
- `--upload` requires the notarized output and cannot be combined with
  `--skip-notarize`; it also needs the GitHub CLI authenticated (`gh auth
  login`).

## Notes

- The embedded `nvim` is a separate binary located at runtime
  (`NvimDiscovery`); releases do not bundle it, so users need Neovim 0.9+.
- In debug builds the hardened runtime is left off so XCTest can inject the
  test bundle into the host app.
- The bundle identifier is `com.mzevo.iNeovim` (T9.4); any future App Group
  identifiers should use the same prefix.
