# Release Checklist

This repository requires a signed Apple Developer build and notarization before publishing releases. Follow these steps every time you cut a new version:

1. **Update version metadata** (if applicable) inside `OverhearApp/Overhear.xcodeproj`.
2. **Install dependencies** (`swift package resolve` inside `OverhearApp` and `xcodebuild -resolvePackageDependencies`).
3. **Build a Release artifact** for Apple Silicon:
   ```sh
   xcbuild -project OverhearApp/Overhear.xcodeproj \
       -scheme Overhear \
       -configuration Release \
       -destination 'platform=macOS,arch=arm64' \
       BUILD_DIR="$PWD/build" clean build
   ```
4. **Codesign the `.app` bundle** with your Developer ID (`Developer ID Application: Keith Herringtion (TEAMID)`). Use `codesign --sign "Developer ID Application: YOUR NAME" --options runtime OverhearApp/build/Release/Overhear.app`.
5. **Notarize** using `xcrun notarytool submit --team-id TEAMID --apple-id YOU@EMAIL --password @keychain:AC_PASSWORD OverhearApp/build/Release/Overhear.app` and wait for success.
6. **Staple** the notarization ticket: `xcrun stapler staple OverhearApp/build/Release/Overhear.app`.
7. **Package** if you ship a `.pkg`/`.dmg` (optional) and verify it uses the notarized `.app`.
8. **Create a GitHub release**:
   ```sh
   gh release create vX.Y.Z ./release/Overhear.app --notes "Release notes here" --title "Overhear vX.Y.Z"
   ```
9. **Update README/docs** with any new screenshots or streaming instructions. Link the release asset in the README if desired.
10. **Comment on the PR** with `@claude review @codex review @copilot review` so the automated reviewers know to rerun their checks.

> Keep `/tmp/overhear.log` handy when testing the release: set `OVERHEAR_FILE_LOGS=1` and `OVERHEAR_USE_FLUIDAUDIO=1` to capture model downloads, streaming updates, and permission prompts before promoting the build.
