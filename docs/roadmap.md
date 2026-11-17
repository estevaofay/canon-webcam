# Roadmap

## Later

- **Drop OBS: ship our own virtual camera from the menu bar app.** The menu bar app is first built as a SwiftPM target bundled by a script (approach A in `docs/superpowers/specs/2026-11-17-menu-bar-app-design.md`). To stop depending on OBS Virtual Camera, move the app into the Xcode project in `Extension/` (approach B) so it embeds and activates the "Canon Webcam" Camera Extension that is already written there. This needs a paid Apple Developer account: the System Extension entitlement, a Developer ID signature and notarization (which would also remove the "Open Anyway" step on first launch).

- **Run the app on macOS 13–26.** `make dmg` bundles Homebrew's libusb, which Homebrew builds for the Mac it is installed on (macOS 27 here), so the app's minimum is macOS 27 for now. Building libusb from its release source with `MACOSX_DEPLOYMENT_TARGET=13.0` in `scripts/make-app.sh` (the app itself already targets 13) would let it run on macOS 13 and later; then set `LSMinimumSystemVersion` in `App/Info.plist` back to 13.0.
