# Roadmap

## Later

- **Drop OBS: ship our own virtual camera from the menu bar app.** The menu bar app is first built as a SwiftPM target bundled by a script (approach A in `docs/superpowers/specs/2026-11-17-menu-bar-app-design.md`). To stop depending on OBS Virtual Camera, move the app into the Xcode project in `Extension/` (approach B) so it embeds and activates the "Canon Webcam" Camera Extension that is already written there. This needs a paid Apple Developer account: the System Extension entitlement, a Developer ID signature and notarization (which would also remove the "Open Anyway" step on first launch).
