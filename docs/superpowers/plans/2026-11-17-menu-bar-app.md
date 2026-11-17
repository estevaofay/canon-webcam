# canon-webcam Menu Bar App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar app, `canon-webcam.app`, shipped as an unsigned DMG built by `make dmg`, that streams a Canon EOS DSLR into OBS Virtual Camera and shows status, preview, output format, battery and a camera-screen switch.

**Architecture:** Split the package so the direct-USB camera code (`CanonUSB`, libusb only) builds without libgphoto2, move the CLI's streaming loop into a shared `WebcamFeed` library, then add a SwiftUI `MenuBarExtra` app target on top of `WebcamFeed`. A shell script assembles the `.app` (bundling libusb), ad-hoc signs it and wraps it in a DMG.

**Tech Stack:** Swift 5.10 / SwiftPM, SwiftUI `MenuBarExtra(.window)`, ServiceManagement `SMAppService`, CoreMediaIO, libusb 1.0 (Homebrew, bundled), XCTest, `hdiutil`, `codesign`, `install_name_tool`.

**Spec:** `docs/superpowers/specs/2026-11-17-menu-bar-app-design.md`

## Global Constraints

- macOS 13+, Apple Silicon (arm64) only; `swift-tools-version:5.10`.
- Build with full Xcode: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the Command Line Tools SDK fails to link, and XCTest needs Xcode).
- The app links libusb only, never libgphoto2. `otool -L` on the app binary and the bundled dylib must show no `/opt/homebrew` path.
- App: name `canon-webcam.app`, executable `canon-webcam`, bundle id `io.github.estevaofay.canon-webcam`, `LSUIElement` = true, `NSCameraUsageDescription` set, ad-hoc signed (`codesign -s -`), not notarized.
- Output is fixed in the app: 24 fps steady, 1920×1080, crop to 16:9 (`FrameRenderer.Mode.fill`), ALO always off while streaming and restored afterwards, virtual camera "OBS Virtual Camera".
- "Show on the camera's screen too" → `EVFOutputDevice` 3; off → 2. Default on in app and CLI; CLI flag `--no-camera-screen`.
- Battery from Canon property `0xD111`: 0 Low, 5 → 25 %, 1 → 50 %, 4 → 75 %, 2 → 100 %.
- Panel copy (exact): status "Live" / "Waiting for a Canon on USB"; title "No camera connected" when none; preview label "What apps see"; empty card "Connect your camera" + "Plug it in over USB and switch it on, with the mode dial on P or M."; figures "fps" / "to video apps", "1080p" / "1920×1080 · 16:9", "camera battery"; rows "Show on the camera's screen too", "Open at login", "Quit canon-webcam" (⌘Q). The UI never says "OBS" except in the virtual-camera-missing problem.
- Never commit a camera serial number. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- CMIO commands (`run`, `check`, `peek`, launching the app) must be run from a Terminal-panel tab or Finder, not from Claude's Bash tool (no camera permission there). USB-only commands (`bench`, `info`) are fine from Bash.

## Review Focus

1. **Quit or switch off while live** → the camera is closed (ALO restored, camera screen back) before `stop()` returns. Pinned in Task 1 (`testStopClosesCameraBeforeReturning`) and Task 3 (`testStopStopsLiveViewAndClosesSink`).
2. **Switch toggled off and on quickly** → never two capture threads fighting over USB. Pinned in Task 1 (`testRestartNeverOverlapsCameras`).
3. **Camera unplugged mid-stream, then replugged** → status returns to waiting within ~3 s and goes live again without relaunch. Pinned in Task 1 (`testDisconnectReconnects`) and Task 3 (`testStatusFollowsCamera`).
4. **OBS Virtual Camera missing at launch, installed later** → problem shown, then live once it appears, without relaunch. Pinned in Task 3 (`testMissingVirtualCameraRecovers`).
5. **Camera permission denied** → a clear problem, live view never started (no silent black video). Pinned in Task 3 (`testAccessDeniedNeverStartsLiveView`).

---

## File Structure

```
Package.swift                                  modify: new targets CanonUSB, WebcamFeed, canon-webcam-app, test targets
Sources/CanonUSB/DirectLiveView.swift          moved from CanonCapture; + camera screen, battery, parsers
Sources/CanonUSB/CanonEvents.swift             new: pure GetEvent parsing + BatteryLevel
Sources/CanonUSB/MacOSCameraDaemon.swift       moved out of EOSCamera.swift
Sources/CanonUSB/LiveView.swift                moved; libgphoto2-free, injectable connector + fallback
Sources/CanonCapture/EOSCamera.swift           keeps libgphoto2 wrapper; CameraError: CameraConnectionError
Sources/CanonCapture/GPhoto2Fallback.swift     new: LiveView helper that adds the libgphoto2 path + onConnect
Sources/WebcamFeed/WebcamFeed.swift            new: start/stop, status, output clock, watchdog, preview
Sources/WebcamFeed/FrameSink.swift             new: FrameSink protocol, SinkConnection (moved from CLI)
Sources/WebcamFeed/FrameStats.swift            moved from CLI (FrameStats, LatestFrame)
Sources/canon-webcam/main.swift                modify: run uses WebcamFeed; --no-camera-screen
Sources/canon-webcam-app/CanonWebcamApp.swift  new: @main, MenuBarExtra, app delegate
Sources/canon-webcam-app/AppModel.swift        new: settings, login item, feed wiring, preview polling
Sources/canon-webcam-app/PanelView.swift       new: the panel (mockup)
Sources/canon-webcam-app/MenuBarIcon.swift     new: template icon with live dot
App/Info.plist                                 new: bundle Info.plist template (__VERSION__)
VERSION                                        new: 0.2.0
scripts/make-app.sh                            new: build, bundle libusb, icon, sign, DMG
scripts/make-icon.swift                        new: draws the 1024 px app icon PNG
Tests/CanonUSBTests/LiveViewTests.swift        new
Tests/CanonUSBTests/CanonEventsTests.swift     new
Tests/WebcamFeedTests/WebcamFeedTests.swift    new
Makefile, README.md, docs/roadmap.md           modify
```

---

### Task 1: `CanonUSB` target and a libgphoto2-free `LiveView`

**Files:**
- Create: `Sources/CanonUSB/` (move `DirectLiveView.swift`, `LiveView.swift`; new `MacOSCameraDaemon.swift`), `Sources/CanonCapture/GPhoto2Fallback.swift`, `Tests/CanonUSBTests/LiveViewTests.swift`
- Modify: `Package.swift`, `Sources/CanonCapture/EOSCamera.swift` (remove `MacOSCameraDaemon`), `Sources/canon-webcam/main.swift` (imports, `LiveView` setup)

**Interfaces:**
- Produces (in `CanonUSB`):
  - `public protocol LiveViewCamera: AnyObject { var model: String { get }; func nextFrame() throws -> Data; func close() }` (`DirectLiveView` conforms).
  - `public protocol CameraConnectionError: Error { var isNoCamera: Bool { get }; var isDisconnect: Bool { get }; var isUnsupported: Bool { get }; var isInUse: Bool { get } }` — `PTPError` conforms (`isUnsupported` = `.unsupported`; `isInUse` = new `Kind.claimFailed(Int32)`, thrown where the USB claim fails instead of `.usb`). `CameraError.isInUse` = `GP_ERROR_IO_USB_CLAIM`.
  - `public struct LiveViewOptions { public var turnOffAutoLightingOptimizer = true; public var showOnCameraScreen = true; public init() }`
  - `public final class LiveView` with `public init(connect: @escaping (LiveViewOptions) throws -> LiveViewCamera = { try DirectLiveView(options: $0) })`, `public var options: LiveViewOptions`, `public var fallback: ((LiveViewOptions) throws -> LiveViewCamera)?` (used after the primary throws an `isUnsupported` error), `public var onFrame: (Data) -> Void`, `public var onEvent: (LiveView.Event) -> Void`, `public func start()`, `public func stop()`. `Event` = `.connected(model: String, direct: Bool)`, `.waiting(reason: String)`, `.cameraInUse` (connect failed with `isInUse`; emitted once per streak like `.waiting`), `.notice(String)`, `.battery(BatteryLevel)` (`.battery` is emitted from Task 2 on).
  - `DirectLiveView.init(options: LiveViewOptions) throws` replaces `init(turnOffAutoLightingOptimizer:)`.
- Produces (in `CanonCapture`, depends on `CanonUSB` + `CGPhoto2`): `CameraError: CameraConnectionError`; `extension LiveView { public func useGPhoto2(preferDirectUSB: Bool, onConnect: ((EOSCamera) throws -> Void)?) }` — sets `fallback` to an `EOSCamera` connector (with the existing `supportsLiveView` check), and when `preferDirectUSB` is false makes libgphoto2 the primary; `onConnect` runs through a temporary `EOSCamera` before the direct connect, as today.
- `LiveView` must keep today's behaviour: latest-frame-wins delivery queue, 10 consecutive failures or an `isDisconnect` error → `.waiting("lost camera (…), reconnecting")`, 1 s pause, reconnect; "no camera found: plug it in over USB and switch it on" for `isNoCamera`; `stop()` waits up to 5 s for the capture thread, which closes the camera.

- [ ] **Step 1: Write the failing tests** in `Tests/CanonUSBTests/LiveViewTests.swift` with a `FakeCamera: LiveViewCamera` (scripted frames/errors, records `closeCount`, global `openCount`/`maxOpen` counters) and a `FakeError: CameraConnectionError`:
  - `testWaitsWhenNoCamera`: connector throws `isNoCamera` → first event is `.waiting(reason:)` containing "no camera found"; no frames.
  - `testDeliversFrames`: connector returns a camera yielding 3 frames → `.connected(model: "Fake", direct: true)` then `onFrame` receives ≥ 1 frame (latest wins) within 1 s.
  - `testDisconnectReconnects`: first camera throws `isDisconnect` after 2 frames, second camera yields frames → events contain `.waiting` with "lost camera" then a second `.connected`; first camera `closeCount == 1`.
  - `testStopClosesCameraBeforeReturning`: start, wait for `.connected`, `stop()` → immediately after it returns, `closeCount == 1`.
  - `testRestartNeverOverlapsCameras`: `start(); stop(); start(); stop()` five times in a row with a connector that counts open cameras → `maxOpen == 1`.
  - `testInUseReportsCameraInUse`: connector throws `isInUse` → event `.cameraInUse`, retried every 2 s.
  - `testUnsupportedUsesFallback`: primary throws `isUnsupported` → `fallback` is called and its camera's frames arrive with `.connected(direct: false)`.

- [ ] **Step 2: Run to verify they fail**
  Run: `swift test --filter CanonUSBTests`
  Expected: build error — no `CanonUSB` module.

- [ ] **Step 3: Create the targets and move the code.** `Package.swift`: `.target(name: "CanonUSB", dependencies: ["CLibUSB"])`; `CanonCapture` depends on `["CGPhoto2", "CanonUSB"]` and re-exports it (`@_exported import CanonUSB` in `GPhoto2Fallback.swift`) so the CLI's `import CanonCapture` keeps working; `.testTarget(name: "CanonUSBTests", dependencies: ["CanonUSB"])`. `LiveView.start()` after a `stop()` must create a fresh thread and reset the stop flag; `stop()` is idempotent.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `swift test --filter CanonUSBTests`
  Expected: 7 tests pass.

- [ ] **Step 5: Check the CLI still streams (hardware, from Bash: USB only)**
  Run: `swift build -c release && .build/release/canon-webcam bench 8` and `.build/release/canon-webcam bench --gphoto2 5`
  Expected: "(direct USB)" at ~30 fps on the T3i; the gphoto2 run says "(libgphoto2)" and streams.

- [ ] **Step 6: Commit** — `git add Package.swift Sources Tests && git commit -m "Split the direct USB camera code into CanonUSB, without libgphoto2"`

---

### Task 2: Camera screen option and battery level

**Files:**
- Create: `Sources/CanonUSB/CanonEvents.swift`, `Tests/CanonUSBTests/CanonEventsTests.swift`
- Modify: `Sources/CanonUSB/DirectLiveView.swift`, `Sources/CanonUSB/LiveView.swift`, `Sources/canon-webcam/main.swift`, `README.md`

**Interfaces:**
- Produces:
  - `public enum CanonEvents { public static func propertyValues(in data: Data) -> [UInt32: UInt32] }` — parses GetEvent records (u32 size, u32 type; type `0xC189` → u32 property, u32 value); stops at a record with size < 8 or past the end. `DirectLiveView.currentSettings()` uses it.
  - `public enum BatteryLevel: Equatable { case low, quarter, half, threeQuarters, full; public init?(canonValue: UInt32); public var text: String }` — `text`: "Low", "25%", "50%", "75%", "100%".
  - `DirectLiveView`: `public private(set) var battery: BatteryLevel?` updated from every GetEvent (connect and housekeeping); `static func evfOutputDevice(showOnCameraScreen: Bool) -> UInt32` (3 / 2), used in `startLiveView`.
  - `LiveView` emits `.battery(level)` after `.connected` and whenever it changes (checked after each frame; `DirectLiveView` only — use `as? DirectLiveView`).
  - CLI: `run` and `check` accept `--no-camera-screen`; `bench` too. Logs "camera battery: 75%" on change.

- [ ] **Step 1: Write the failing tests** in `CanonEventsTests.swift`:
  - `testPropertyValuesParsesPropertyChanges`: bytes for records `(16, 0xC189, 0xD1C1, 3)`, `(12, 0xC18A, 0xD1B0)`, `(16, 0xC189, 0xD111, 4)`, terminator `(8, 0)` → `[0xD1C1: 3, 0xD111: 4]`.
  - `testPropertyValuesStopsAtTruncatedRecord`: second record claims size 40 with 10 bytes left → only the first record's value.
  - `testBatteryLevelMapping`: `BatteryLevel(canonValue:)` for 0,5,1,4,2 → `.low,.quarter,.half,.threeQuarters,.full`; for 3 → nil; `.threeQuarters.text == "75%"`.
  - `testEVFOutputDevice`: `DirectLiveView.evfOutputDevice(showOnCameraScreen: true) == 3`, `false == 2`.

- [ ] **Step 2: Run to verify they fail** — `swift test --filter CanonEventsTests` → build errors (undefined symbols).

- [ ] **Step 3: Implement** the four interfaces above; `LiveViewOptions.showOnCameraScreen` flows into `startLiveView`.

- [ ] **Step 4: Run tests** — `swift test` → all pass.

- [ ] **Step 5: Hardware check (Bash)** — `.build/release/canon-webcam bench 8` shows the picture on the camera's screen and ~30 fps; `bench --no-camera-screen 8` leaves the camera screen dark. Run `info` before and after: battery reading from the app path matches libgphoto2's `batterylevel`.

- [ ] **Step 6: README** — usage block gets `--no-camera-screen`; camera tips: live view now also shows on the camera's screen by default.

- [ ] **Step 7: Commit** — `"Show live view on the camera's screen too, and read the battery level"`

---

### Task 3: `WebcamFeed` library shared by CLI and app

**Files:**
- Create: `Sources/WebcamFeed/WebcamFeed.swift`, `Sources/WebcamFeed/FrameSink.swift`, `Sources/WebcamFeed/FrameStats.swift`, `Tests/WebcamFeedTests/WebcamFeedTests.swift`
- Modify: `Package.swift` (`.target(name: "WebcamFeed", dependencies: ["CanonUSB", "VirtualCamera"])`, test target, CLI depends on it), `Sources/canon-webcam/main.swift` (`run` becomes a thin wrapper; `FrameStats`/`LatestFrame`/`SinkConnection` move out)

**Interfaces:**
- Consumes: `LiveView`, `LiveViewOptions`, `BatteryLevel` (Tasks 1–2); `VirtualCameraSink`, `VirtualCameraError`, `FrameRenderer`.
- Produces:
  - `public protocol FrameSink: AnyObject { func send(_ frame: CVPixelBuffer); var sent: Int { get }; var dropped: Int { get }; func stop() }` — `VirtualCameraSink` conforms.
  - `public struct FeedSettings { public var cameraName = "OBS Virtual Camera"; public var outputFPS: Double = 24; public var mode: FrameRenderer.Mode = .fill; public var liveView = LiveViewOptions(); public init() }`
  - `public enum FeedProblem: Equatable { case virtualCameraMissing(name: String), cameraAccessDenied, cameraInUse }`
  - `public enum FeedStatus: Equatable { case stopped, waitingForCamera(reason: String), live(model: String), problem(FeedProblem) }`
  - `public final class WebcamFeed` with `public init(settings: FeedSettings, liveView: LiveView = LiveView(), openSink: @escaping (String) throws -> FrameSink = { try VirtualCameraSink(cameraNamed: $0) }, cameraAccess: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized })`; `public private(set) var status: FeedStatus`, `battery: BatteryLevel?`, `sentFPS: Double` (frames actually sent per second over the last 2 s); `public var onChange: () -> Void` (called on the main queue after any of those change); `public var onLog: (String) -> Void` (the CLI's existing log lines, verbatim); `public func start()`, `public func stop()` (blocking, idempotent); `public func latestFrame() -> CVPixelBuffer?` (newest rendered frame ≤ 1 s old, for the preview); `public func setShowOnCameraScreen(_ on: Bool)` (stores it and, if live, restarts live view so it applies).
- Behaviour moved verbatim from `run`: steady output clock at `outputFPS` resending the newest frame ≤ 1 s old; 2 s watchdog that reopens the sink when it is closed or stops taking frames; 10 s stats log line. New: `start()` checks `cameraAccess()` first → `.problem(.cameraAccessDenied)` and returns without starting live view; a failed `openSink` with `VirtualCameraError.notFound`/`.noSink` → `.problem(.virtualCameraMissing(name:))`, retried by the watchdog every 2 s, and the status follows the camera once the sink opens; a `.cameraInUse` event → `.problem(.cameraInUse)` (cleared by the next `.connected` or a `.waiting` for no camera).

- [ ] **Step 1: Write the failing tests** (`FakeSink`, a `LiveView` built with a fake connector from Task 1's test helpers copied into this test target, `cameraAccess` closure):
  - `testAccessDeniedNeverStartsLiveView`: `cameraAccess: { false }` → after `start()`, `status == .problem(.cameraAccessDenied)` and the fake connector was never called.
  - `testMissingVirtualCameraRecovers`: `openSink` throws `VirtualCameraError.notFound` twice then returns a `FakeSink` → status `.problem(.virtualCameraMissing(name: "OBS Virtual Camera"))`, then `.live(model: "Fake")` within 5 s; the sink receives frames.
  - `testStatusFollowsCamera`: fake camera connects, streams, then disconnects with no second camera → `.live(model:)` then `.waitingForCamera(reason:)` within 3 s.
  - `testSteadyOutputRepeatsNewestFrame`: camera yields one frame then blocks; `outputFPS = 24` → over 1 s the sink gets 20…26 frames; after 1.5 s total with no new frame, sends stop.
  - `testStopStopsLiveViewAndClosesSink`: live, `stop()` → fake camera `closeCount == 1`, sink `stop` called, `status == .stopped`; a second `stop()` is a no-op.

- [ ] **Step 2: Run to verify they fail** — `swift test --filter WebcamFeedTests` → build errors.

- [ ] **Step 3: Implement `WebcamFeed`**, then rewrite the CLI `run` as: `ensureCameraAccess()`; build `FeedSettings` from flags; `liveView.useGPhoto2(preferDirectUSB:onConnect:)`; `feed.onLog = log`; on `.problem(.virtualCameraMissing)` at start, `fail(...)` with the existing `VirtualCameraError` text (CLI behaviour unchanged); `runUntilInterrupted { feed.stop() }`.

- [ ] **Step 4: Run tests** — `swift test` → all pass.

- [ ] **Step 5: Hardware check in the Terminal tab** — `make install`, then `canon-webcam check 20` → `PASS`; `canon-webcam` for 30 s → log lines identical in shape to before ("… fps from camera …, sent 24.0 fps …"); Ctrl-C → camera screen returns, ALO back (verify with `scratchpad lv secs=0 dump=1` or `canon-webcam info`).

- [ ] **Step 6: Commit** — `"Move the streaming loop into WebcamFeed, shared by the CLI and the app"`

---

### Task 4: The menu bar app

**Files:**
- Create: `Sources/canon-webcam-app/CanonWebcamApp.swift`, `AppModel.swift`, `PanelView.swift`, `MenuBarIcon.swift`
- Modify: `Package.swift` (`.executableTarget(name: "canon-webcam-app", dependencies: ["WebcamFeed"])`, product `.executable(name: "canon-webcam-app", targets: ["canon-webcam-app"])`)

**Interfaces:**
- Consumes: `WebcamFeed`, `FeedSettings`, `FeedStatus`, `FeedProblem`, `BatteryLevel`.
- Produces: `@MainActor final class AppModel: ObservableObject` with `@Published var isOn: Bool` (UserDefaults key `streaming`, default true), `@Published var showOnCameraScreen: Bool` (key `showOnCameraScreen`, default true), `@Published var openAtLogin: Bool` (reads/writes `SMAppService.mainApp`), `@Published private(set) var status: FeedStatus`, `battery: BatteryLevel?`, `sentFPS: Double`, `preview: CGImage?`; `func panelAppeared()` / `func panelDisappeared()` start/stop a 5 fps preview timer that scales `feed.latestFrame()` to 640 px wide via a shared `CIContext`; `func shutdown()` (calls `feed.stop()`).

Behaviour:
- `CanonWebcamApp`: `MenuBarExtra { PanelView(model:) } label: { MenuBarIcon(live:) }.menuBarExtraStyle(.window)`; `NSApplicationDelegateAdaptor` whose `applicationWillTerminate` calls `model.shutdown()`. On launch: if `AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined`, `requestAccess`, then `feed.start()` when `isOn`.
- `isOn` false → `feed.stop()`; true → `feed.start()`.
- `PanelView` follows the Paper mockup "1 · Streaming" / "2 · Waiting for camera" (Global Constraints has the exact copy), ~330 pt wide, system font, standard `Toggle`s (`.switch` style, `.controlSize(.small)` for the camera-screen row). Figures row shows `Int(sentFPS.rounded())`. Problems replace the preview card: `.virtualCameraMissing` → "Install OBS and allow its camera extension once." + button "Get OBS" (opens `https://obsproject.com/download`); `.cameraAccessDenied` → "canon-webcam needs camera access to feed the virtual camera." + button "Open Privacy Settings" (`x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`); `.cameraInUse` → "Another app is using the camera (Photos, Image Capture, EOS Utility…)." Off state: title stays, status "Off", preview card "Streaming is off."
- `MenuBarIcon`: SF Symbol `camera` as template; when live, a 6 pt red (`#E5322D`) dot top-right.

- [ ] **Step 1: Build** — `swift build -c release --product canon-webcam-app` → succeeds with no warnings in the new files.

- [ ] **Step 2: Smoke run from the Terminal tab** (camera permission belongs to the terminal here) — `.build/release/canon-webcam-app`: icon appears in the menu bar; panel shows "Waiting for a Canon on USB" with no camera, then "Live" with preview, "24 fps", "1080p", battery once the T3i is on; toggling the main switch off releases the camera (`canon-webcam bench 3` from Bash then works); toggling "Show on the camera's screen too" changes the camera screen within ~2 s; Quit restores ALO.

- [ ] **Step 3: Compare with the mockup** — screenshot the open panel and put it next to the Paper artboards; fix spacing/copy differences.

- [ ] **Step 4: Commit** — `"Add the canon-webcam menu bar app"`

---

### Task 5: Bundle, sign and package as a DMG

**Files:**
- Create: `App/Info.plist`, `VERSION` (`0.2.0`), `scripts/make-app.sh`, `scripts/make-icon.swift`
- Modify: `Makefile` (targets `app`, `dmg`), `.gitignore` (`/dist/`), `README.md` (Install: "Download the DMG" first, Open Anyway steps, OBS still required, permission re-asked after each update; building from source stays), `docs/roadmap.md` (unchanged content, check link)

**Interfaces:**
- `scripts/make-app.sh` (bash, `set -euo pipefail`) produces `dist/canon-webcam.app` and, with `--dmg`, `dist/canon-webcam-$(cat VERSION).dmg`. Steps: `swift build -c release --product canon-webcam-app`; create `Contents/{MacOS,Frameworks,Resources}`; copy binary to `Contents/MacOS/canon-webcam`; `sed s/__VERSION__/…/` Info.plist; find libusb's path with `otool -L` (don't hardcode), copy it to `Frameworks/`, `install_name_tool -id @rpath/libusb-1.0.0.dylib` on the copy and `-change <old> @executable_path/../Frameworks/libusb-1.0.0.dylib` on the binary; `swift scripts/make-icon.swift Resources/icon_1024.png` → `sips` sizes → `iconutil` → `AppIcon.icns`; `codesign --force -s - Frameworks/*.dylib`, then `codesign --force -s - dist/canon-webcam.app`; fail if `otool -L` of binary or dylib still contains `/opt/homebrew`. DMG: staging folder with the app and an `Applications` symlink, `hdiutil create -volname canon-webcam -srcfolder <staging> -ov -format UDZO`.
- `App/Info.plist` keys: `CFBundleExecutable` canon-webcam, `CFBundleIdentifier` io.github.estevaofay.canon-webcam, `CFBundleName`/`CFBundleDisplayName` canon-webcam, `CFBundleShortVersionString` and `CFBundleVersion` `__VERSION__`, `CFBundlePackageType` APPL, `CFBundleIconFile` AppIcon, `LSMinimumSystemVersion` 13.0, `LSUIElement` true, `NSCameraUsageDescription` "canon-webcam feeds your DSLR's picture into a virtual camera, which macOS treats as camera access.", `NSHumanReadableCopyright` "MIT License".
- Make: `app: ; scripts/make-app.sh`, `dmg: ; scripts/make-app.sh --dmg`.

- [ ] **Step 1: Run** `make dmg` → prints the DMG path; exits 0.
- [ ] **Step 2: Verify the bundle** — `otool -L dist/canon-webcam.app/Contents/MacOS/canon-webcam` shows `@executable_path/../Frameworks/libusb-1.0.0.dylib` and only system paths; `codesign --verify --deep --strict dist/canon-webcam.app` exits 0; `hdiutil verify dist/canon-webcam-0.2.0.dmg` exits 0; `plutil -lint App/Info.plist` OK.
- [ ] **Step 3: Install like a user** — open the DMG, drag to Applications, launch from Finder; macOS blocks it → System Settings → Privacy & Security → Open Anyway; camera prompt names canon-webcam; Meet shows the T3i through OBS Virtual Camera; Quit → ALO restored, camera screen back. Also: Open at login appears in System Settings → General → Login Items when ticked.
- [ ] **Step 4: README** — Install section rewritten as above; screenshot of the panel optional.
- [ ] **Step 5: Commit** — `"Package the menu bar app as a DMG: make dmg"`
