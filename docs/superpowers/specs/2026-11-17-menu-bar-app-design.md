# canon-webcam menu bar app — design

Status: draft for approval (2026-11-17)
Mockups: Paper file "canon-webcam — Menu bar app", artboards "1 · Streaming" and "2 · Waiting for camera".

## Intent

Today canon-webcam is a command-line tool you start in a terminal and stop with Ctrl-C. The goal is a normal Mac app that anyone can download as a DMG, drag to Applications, and control from the menu bar: plug in an old Canon, and it shows up as a webcam in Zoom, Meet or FaceTime. It is for the owner of the repo first and for other owners of old Canon bodies who find the project on GitHub.

## Goals

- A menu bar app (no Dock icon, no main window) that streams the DSLR into a virtual camera, reconnects by itself, and shows what is happening at a glance.
- Downloadable as a DMG from GitHub Releases. No Homebrew, no terminal, no Xcode needed to *use* it.
- Built with one command from the repo: `make dmg`.
- Keep the command-line tool, sharing the same streaming code.

## Non-goals (for now)

- Our own virtual camera (no OBS). That needs a paid Apple Developer account; see "Later".
- Signing with a Developer ID or notarization. The DMG is unsigned; first launch needs System Settings → Privacy & Security → **Open Anyway**. This is accepted.
- Settings for frame rate, framing, exposure, Auto Lighting Optimizer; snapshots; a "test with a video app" action. (All exist in the CLI; deliberately not in the app.)
- Intel Macs (Homebrew's libusb, which we bundle, is arm64 here). Cameras other than Canon EOS.

## Anti-goals

- A cluttered panel. The owner's feedback on the first mockup was "too much": every control has to earn its place.
- Leaving the camera in a bad state: ALO off, live view stuck, or the camera held after the app stops streaming or quits.

## What the user sees

Menu bar icon: a camera glyph (template image, follows light/dark menu bar). A small red dot while live.

Panel (SwiftUI, Control Center style, ~330 pt wide), top to bottom:

1. **Header**: camera model ("Canon EOS Rebel T3i"), status line with a dot (red "Live" / grey "Waiting for a Canon on USB"), and the main on/off switch.
2. **Preview**: what apps see, 16:9, labelled "What apps see". Updates a few times a second, only while the panel is open. Without a camera: a dashed card, "Connect your camera — plug it in over USB and switch it on, with the mode dial on P or M."
3. **Figures** (only when live): output frame rate ("24 fps, to video apps"), format ("1080p, 1920×1080 · 16:9"), camera battery (Low / 25 / 50 / 75 / 100 %).
4. **Show on the camera's screen too**: switch.
5. **Open at login** (checkmark) and **Quit canon-webcam** (⌘Q).

Problems that stop streaming are shown in the preview card's place, with one plain sentence and, where possible, a button:
- OBS Virtual Camera not installed or not allowed → "Install OBS and allow its camera extension once" + button that opens the OBS download page.
- Camera permission denied → button that opens System Settings → Privacy & Security → Camera.
- Another app has the camera (claim fails) → "Another app is using the camera (Photos, Image Capture, EOS Utility…)."

## Behaviour

- **On launch**: switch is on (remembered across launches), app asks for camera permission (feeding a virtual camera counts as camera access), then waits for a camera and streams as soon as one appears. Same reconnect loop as the CLI.
- **Main switch off**: stop streaming, restore the camera (ALO back, live view off, screen back on), release USB so other apps can use the camera. Switch on: start again.
- **Quit / logout / shutdown**: same clean stop as switch off.
- **Fixed output**: 24 fps steady (repeat newest frame), 1920×1080, crop to 16:9. ALO always off while streaming and restored afterwards (existing per-camera saved-setting logic).
- **Show on the camera's screen too**: when on, live view goes to camera screen *and* computer (EVFOutputDevice 3 instead of 2). Tested on the T3i: 30 fps either way. Default: on. Changing it applies immediately (or on the next reconnect, if that is simpler).
- **Open at login**: `SMAppService.mainApp`. Default: off.
- Settings persist in `UserDefaults`.

## Approaches considered

- **A. New SwiftPM app target in this package, bundled by a script (chosen).** Reuses `CanonCapture` and `VirtualCamera`; `make dmg` builds the release binary, assembles `canon-webcam.app`, copies libusb into `Contents/Frameworks`, rewrites its install name, ad-hoc signs, and builds the DMG with `hdiutil`. Fast to start, one build system for CLI and app, no Xcode needed. Downside: moving to our own Camera Extension later means moving the app into an Xcode project.
- **B. Grow the existing `Extension/` host app (Xcode project via xcodegen) into the menu bar app.** Ready for the extension later, but ships a virtual camera that can't load until there is a paid account, and every build needs full Xcode. Deferred; see "Later".

## How it gets built (owner-decided parts)

- Approach A.
- Unsigned (ad-hoc) DMG; first launch via Open Anyway.
- OBS Virtual Camera stays the target for now, but the app never names it in normal operation.

## Builder's calls (made in this design, open to change)

- **Shared streaming core**: move the feed logic now in `Sources/canon-webcam/main.swift` (`SinkConnection`, `LatestFrame`, output clock, watchdog, frame stats) into a new library target (e.g. `WebcamFeed`) with a small observable API: start/stop, state (waiting reason / live), model, output fps, battery, latest preview frame. The CLI's `run` and the app both use it.
- **The app uses only the direct USB path (libusb)**, not libgphoto2. Split `CanonCapture` so the direct path (`DirectLiveView`, `MacOSCameraDaemon`) builds without libgphoto2; the CLI keeps both. Reason: libgphoto2 drags in libltdl, libexif, libintl and runtime-loaded camera plugins that would all have to be bundled and relocated; libusb is one dylib with no dependencies. Cost: the app supports Canon EOS bodies only (every camera this project targets).
- **Battery** read from Canon property 0xD111 in the GetEvent stream (0 Low, 5 25 %, 1 50 %, 4 75 %, 2 100 %, per libgphoto2's table), exposed by `DirectLiveView`.
- **Camera screen** option added to `DirectLiveView` (`EVFOutputDevice` 3 vs 2). On by default in both app and CLI (no frame-rate cost); the CLI gets `--no-camera-screen` to turn it off. Documented in README.
- **App name and id**: `canon-webcam.app`, bundle id `io.github.estevaofay.canon-webcam`, `LSUIElement` true, `NSCameraUsageDescription` set, macOS 13+ (`MenuBarExtra` with `.window` style).
- **Font and look**: system font and standard SwiftUI controls; the Paper mockup uses Inter only because SF Pro isn't available there.
- **Version** from a `VERSION` file or git tag, put into Info.plist by the bundling script.
- **App icon**: a simple generated icon (camera glyph); can be replaced later.
- **Camera permission resets** on every rebuild (ad-hoc signatures change); acceptable for now, mention in README.

## Testing

- Unit-level: the shared core's state machine with a fake camera source (connect, frames, disconnect, stop) — no hardware.
- Hardware, by hand, on the T3i and T5: launch from the DMG on a clean-ish setup (no Homebrew libs on the path, e.g. check `otool -L` shows only system libs and `@rpath/libusb`), Open Anyway, permission prompt, live in Meet, switch off/on, unplug/replug, quit while live → ALO restored and camera screen back.
- `canon-webcam check` still passes for the CLI after the refactor.

## Later

- Approach B: move the app into the Xcode project in `Extension/` and ship our own "Canon Webcam" Camera Extension, dropping OBS. Needs a paid Apple Developer account (System Extension entitlement, Developer ID, notarization). Tracked in `docs/roadmap.md`.
