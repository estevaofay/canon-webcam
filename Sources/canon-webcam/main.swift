import AVFoundation
import CanonCapture
import CoreImage
import Foundation
import VirtualCamera

let usage = """
canon-webcam: use an old Canon EOS DSLR (Rebel T3i/600D, T5/1200D, ...) as a webcam on macOS.

USAGE
  canon-webcam [run] [--camera NAME] [--fit] [--expose] [--fps N] [--keep-alo]
                   [--no-camera-screen] [--gphoto2]
      Stream the DSLR's live view into a virtual camera until Ctrl-C.
      --camera NAME  virtual camera to feed (default: "OBS Virtual Camera";
                     use "Canon Webcam" for this project's own extension)
      --fit          show the whole 3:2 frame with side bars (default: crop to 16:9)
      --expose       set 1/60s and ISO Auto on connect (mode dial on M)
      --fps N        send video apps a steady N frames per second, repeating the
                     newest camera frame when the next isn't ready (default: 24;
                     0 sends each camera frame as soon as it arrives)
      --keep-alo     leave Auto Lighting Optimizer as set on the camera. By default
                     it is switched off while streaming (about 28 instead of 21
                     fps on a Rebel T5) and restored when canon-webcam stops
      --no-camera-screen
                     send live view only to the computer (by default it also
                     shows on the camera's own screen)
      --gphoto2      read live view through libgphoto2 instead of the faster
                     direct USB path (slower; for troubleshooting)
  canon-webcam check [--camera NAME] [--no-camera-screen] [SECONDS]
      Feed the virtual camera and read it back like a video app would, to
      confirm the DSLR's frames come out the other side (default: 15s).
  canon-webcam peek [--camera NAME] [-o FILE] [SECONDS]
      Watch a virtual camera like a video app (read-only, safe to run next to
      a running feed) and save the last frame it shows (default: peek.jpg).
  canon-webcam cameras          list virtual cameras that accept frames
  canon-webcam info             show the connected DSLR and its exposure settings
  canon-webcam expose           set webcam-friendly exposure: 1/60s, ISO Auto
  canon-webcam snap [FILE]      save one live-view frame (default: snap.jpg)
  canon-webcam bench [--keep-alo] [--no-camera-screen] [--gphoto2] [SECONDS]
                                measure live-view frame rate (default: 15s)

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(time)] \(message)")
    fflush(stdout)
}

/// Runs until Ctrl-C (or the terminal closes, or `kill`), then calls `cleanup`
/// so the camera is left in a clean state.
func runUntilInterrupted(cleanup: @escaping () -> Void) -> Never {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)  // the terminal window was closed
    let sources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            print("")
            log("stopping…")
            cleanup()
            exit(0)
        }
        source.resume()
        return source
    }
    _ = sources
    // A real CFRunLoop, not dispatchMain(): CoreMediaIO's client side delivers
    // queued frames to the camera extension from the main run loop.
    while true { CFRunLoopRun() }
}

final class FrameStats {
    private let lock = NSLock()
    private var frames = 0
    private var gaps: [Double] = []
    private var last: Date?

    func frame() {
        lock.withLock {
            let now = Date()
            if let last { gaps.append(now.timeIntervalSince(last)) }
            last = now
            frames += 1
        }
    }

    /// Returns (fps, median gap ms, max gap ms) since the last call, and resets.
    func take() -> (fps: Double, medianMs: Double, maxMs: Double, frames: Int) {
        lock.withLock {
            defer { gaps.removeAll(keepingCapacity: true); frames = 0 }
            guard !gaps.isEmpty else { return (0, 0, 0, frames) }
            let sorted = gaps.sorted()
            let total = gaps.reduce(0, +)
            return (Double(gaps.count) / total, sorted[sorted.count / 2] * 1000, sorted.last! * 1000, frames)
        }
    }
}

/// Virtual cameras are cameras: macOS only lets an app send frames to (or
/// read from) one after the user allows camera access. For a command-line
/// tool the permission belongs to the app it runs in (Terminal, iTerm, ...).
/// Without it, CoreMediaIO silently delivers nothing.
func ensureCameraAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return
    case .notDetermined:
        log("asking macOS for camera access (needed to feed a virtual camera)…")
        let done = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { granted = $0; done.signal() }
        done.wait()
        if granted { return }
        fallthrough
    default:
        fail("""
            camera access is not allowed for the app running canon-webcam, so macOS blocks it from \
            feeding a virtual camera. Allow it in System Settings > Privacy & Security > Camera \
            (for Terminal, iTerm, ...), then run canon-webcam again.
            """)
    }
}

func setWebcamExposure(_ camera: EOSCamera) throws {
    try camera.setSetting("shutterspeed", "1/60")
    try camera.setSetting("iso", "Auto")
}

// MARK: - Commands

/// The current connection to the virtual camera. Camera extensions can restart
/// (another app quits, macOS relaunches them), which silently strands an open
/// sink; `run` swaps in a fresh one when that happens.
final class SinkConnection {
    let cameraName: String
    private let lock = NSLock()
    private var sink: VirtualCameraSink?
    private(set) var sentBefore = 0
    private(set) var droppedBefore = 0

    init(cameraName: String) { self.cameraName = cameraName }

    var isOpen: Bool { lock.withLock { sink != nil } }
    /// Totals across reconnections.
    var sent: Int { lock.withLock { sentBefore + (sink?.sent ?? 0) } }
    var dropped: Int { lock.withLock { droppedBefore + (sink?.dropped ?? 0) } }

    func send(_ frame: CVPixelBuffer) { lock.withLock { sink?.send(frame) } }

    @discardableResult
    func open() throws -> VirtualCameraSink {
        let new = try VirtualCameraSink(cameraNamed: cameraName)
        lock.withLock { sink = new }
        return new
    }

    func close() {
        lock.withLock {
            guard let old = sink else { return }
            sentBefore += old.sent
            droppedBefore += old.dropped
            old.stop()
            sink = nil
        }
    }
}

/// The newest rendered camera frame, for the output clock to send.
final class LatestFrame {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var arrived = Date.distantPast

    func set(_ frame: CVPixelBuffer) { lock.withLock { self.frame = frame; arrived = Date() } }

    /// The newest frame, unless it is older than `maxAge` (camera stalled or gone).
    func get(maxAge: TimeInterval) -> CVPixelBuffer? {
        lock.withLock { Date().timeIntervalSince(arrived) <= maxAge ? frame : nil }
    }
}

func run(cameraName: String, mode: FrameRenderer.Mode, expose: Bool, fps: Double, direct: Bool, keepALO: Bool,
         cameraScreen: Bool) -> Never {
    ensureCameraAccess()
    let connection = SinkConnection(cameraName: cameraName)
    do { try connection.open() } catch { fail("\(error)") }
    let output = fps > 0 ? String(format: "steady %g fps", fps) : "camera frame rate"
    log("feeding \"\(cameraName)\" (\(mode.rawValue) mode, \(output)). Ctrl-C to stop.")

    let renderer = FrameRenderer(mode: mode)
    let stats = FrameStats()
    let live = LiveView()
    live.useGPhoto2(preferDirectUSB: direct, onConnect: expose ? setWebcamExposure : nil)
    live.options.turnOffAutoLightingOptimizer = !keepALO
    live.options.showOnCameraScreen = cameraScreen
    let counterLock = NSLock()
    var cameraFrames = 0
    let latest = LatestFrame()
    live.onEvent = { event in
        switch event {
        case let .connected(model, direct):
            log("camera connected: \(model), live view on (\(direct ? "direct USB" : "libgphoto2"))")
        case let .waiting(reason): log("waiting: \(reason)")
        case let .notice(message): log("note: \(message)")
        case .cameraInUse: log("waiting: another app is using the camera (Photos, Image Capture, EOS Utility…)")
        case let .battery(level): log("camera battery: \(level.text)")
        }
    }
    live.onFrame = { jpeg in
        counterLock.withLock { cameraFrames += 1 }
        if let frame = renderer.render(jpeg: jpeg) {
            if fps > 0 { latest.set(frame) } else { connection.send(frame) }
            stats.frame()
        }
    }
    live.start()

    // Output clock: video apps get frames at a steady rate. When the camera
    // hasn't produced a new frame yet, the newest one is sent again; after a
    // second without frames (camera stalled or unplugged) nothing is sent.
    let clockQueue = DispatchQueue(label: "canon-webcam.output", qos: .userInteractive)
    let clock = DispatchSource.makeTimerSource(flags: .strict, queue: clockQueue)
    if fps > 0 {
        clock.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
        clock.setEventHandler {
            if let frame = latest.get(maxAge: 1) { connection.send(frame) }
        }
        clock.resume()
    }

    // Watchdog: if the camera keeps delivering but the virtual camera stopped
    // taking frames for ~2s, its extension restarted or something else took
    // over its input. Reconnect by name.
    var watchFrames = 0
    var watchSent = 0
    let watchdog = DispatchSource.makeTimerSource(queue: .main)
    watchdog.schedule(deadline: .now() + 2, repeating: 2)
    watchdog.setEventHandler {
        let frames = counterLock.withLock { cameraFrames }
        let sent = connection.sent
        defer { watchFrames = frames; watchSent = sent }
        if !connection.isOpen {
            if (try? connection.open()) != nil { log("reconnected to \"\(cameraName)\"") }
            return
        }
        if frames - watchFrames >= 5 && sent == watchSent {
            log("\"\(cameraName)\" stopped taking frames (its extension restarted, or another app "
                + "such as OBS started feeding it); reconnecting")
            connection.close()
            if (try? connection.open()) != nil {
                log("reconnected to \"\(cameraName)\"")
            } else {
                log("waiting for \"\(cameraName)\" to come back")
            }
        }
    }
    watchdog.resume()

    var lastSent = 0
    var lastDropped = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler {
        let s = stats.take()
        let sent = connection.sent - lastSent, dropped = connection.dropped - lastDropped
        lastSent = connection.sent; lastDropped = connection.dropped
        guard s.frames > 0 else { return }
        log(String(format: "%.1f fps from camera (median gap %.0f ms, max %.0f ms), sent %.1f fps, dropped %d",
                   s.fps, s.medianMs, s.maxMs, Double(sent) / 10, dropped))
    }
    timer.resume()

    runUntilInterrupted {
        if fps > 0 { clock.cancel() }
        timer.cancel()
        watchdog.cancel()
        live.stop()
        connection.close()
    }
}

func check(cameraName: String, seconds: Double, cameraScreen: Bool) -> Never {
    ensureCameraAccess()
    let sink: VirtualCameraSink
    let reader: VirtualCameraReader
    do {
        sink = try VirtualCameraSink(cameraNamed: cameraName)
        reader = try VirtualCameraReader(cameraNamed: cameraName)
    } catch { fail("\(error)") }

    let renderer = FrameRenderer()
    let live = LiveView()
    live.useGPhoto2(preferDirectUSB: true)
    live.options.showOnCameraScreen = cameraScreen
    let lock = NSLock()
    var cameraFrames = 0
    live.onEvent = { event in
        switch event {
        case let .connected(model, _): log("camera connected: \(model)")
        case let .waiting(reason): log("waiting: \(reason)")
        case let .notice(message): log("note: \(message)")
        case .cameraInUse: log("waiting: another app is using the camera (Photos, Image Capture, EOS Utility…)")
        case let .battery(level): log("camera battery: \(level.text)")
        }
    }
    live.onFrame = { jpeg in
        guard let frame = renderer.render(jpeg: jpeg) else { return }
        lock.withLock {
            sink.send(frame)
            cameraFrames += 1
        }
    }
    log("feeding \"\(cameraName)\" and reading it back for \(Int(seconds))s…")
    live.start()

    var ours = 0, other = 0
    let start = Date()
    let poll = DispatchSource.makeTimerSource(queue: .main)
    poll.schedule(deadline: .now(), repeating: 0.01)
    poll.setEventHandler {
        let ids = reader.drain()
        lock.withLock {
            for id in ids {
                if id != 0 && sink.sentSurfaceIDs.contains(id) { ours += 1 } else { other += 1 }
            }
        }
        guard Date().timeIntervalSince(start) >= seconds else { return }
        poll.cancel()
        live.stop()
        reader.stop()
        sink.stop()
        print("""

            camera frames sent:            \(cameraFrames)
            frames out of "\(cameraName)": \(ours + other)
              - the DSLR's own frames:    \(ours) (\(String(format: "%.1f", Double(ours) / seconds)) fps)
              - other (placeholder etc.): \(other)
            """)
        if ours > 0 {
            print("PASS: video apps using \"\(cameraName)\" see the DSLR.")
            exit(0)
        }
        print("FAIL: no DSLR frames came out of \"\(cameraName)\".")
        exit(1)
    }
    poll.resume()
    runUntilInterrupted { live.stop(); reader.stop(); sink.stop() }
}

/// Watches a virtual camera like a video app would (read-only: it does not
/// feed it, so it is safe to run next to `canon-webcam run`) and saves the
/// last frame it saw.
func peek(cameraName: String, seconds: Double, output: String) -> Never {
    ensureCameraAccess()
    let reader: VirtualCameraReader
    do { reader = try VirtualCameraReader(cameraNamed: cameraName) } catch { fail("\(error)") }
    log("watching \"\(cameraName)\" for \(Int(seconds))s…")

    var frames = 0
    var surfaces = Set<IOSurfaceID>()
    var last: CVPixelBuffer?
    let start = Date()
    let poll = DispatchSource.makeTimerSource(queue: .main)
    poll.schedule(deadline: .now(), repeating: 0.01)
    poll.setEventHandler {
        for frame in reader.drainFrames() {
            frames += 1
            last = frame
            if let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() {
                surfaces.insert(IOSurfaceGetID(surface))
            }
        }
        guard Date().timeIntervalSince(start) >= seconds else { return }
        poll.cancel()
        reader.stop()
        print(String(format: "frames out of \"%@\": %d (%.1f fps), %d distinct buffers",
                     cameraName, frames, Double(frames) / seconds, surfaces.count))
        guard let last else { print("no frames at all: is the camera extension running?"); exit(1) }
        let image = CIImage(cvPixelBuffer: last)
        let context = CIContext()
        do {
            try context.writeJPEGRepresentation(
                of: image, to: URL(fileURLWithPath: output),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
            print("saved what video apps see to \(output) (\(CVPixelBufferGetWidth(last))x\(CVPixelBufferGetHeight(last)))")
        } catch { fail("could not save \(output): \(error)") }
        exit(0)
    }
    poll.resume()
    runUntilInterrupted { reader.stop() }
}

func listCameras() {
    let cameras = VirtualCameras.all()
    if cameras.isEmpty { print("No cameras visible to CoreMediaIO."); return }
    for camera in cameras {
        print("\(camera.acceptsFrames ? "✓ accepts frames" : "  camera only    ")  \(camera.name)")
    }
}

func connect() -> EOSCamera {
    do { return try EOSCamera() } catch { fail("\(error)") }
}

func info() {
    let camera = connect()
    print("Model (libgphoto2): \(camera.model)")
    print("Live view:          \(camera.supportsLiveView ? "supported" : "not supported")")
    for key in ["cameramodel", "autoexposuremode", "shutterspeed", "aperture", "iso", "focusmode", "batterylevel"] {
        if let value = try? camera.setting(key) {
            print("\(key.padding(toLength: 19, withPad: " ", startingAt: 0)) \(value)")
        }
    }
}

func expose() {
    let camera = connect()
    do {
        try setWebcamExposure(camera)
        print("shutterspeed \(try camera.setting("shutterspeed")), iso \(try camera.setting("iso"))")
    } catch { fail("\(error) (exposure can only be set remotely with the mode dial on M)") }
}

func snap(_ path: String) {
    let camera = connect()
    do {
        let jpeg = try camera.capturePreview()
        try jpeg.write(to: URL(fileURLWithPath: path))
        print("saved \(path) (\(jpeg.count / 1024) KB)")
    } catch { fail("\(error)") }
}

func bench(seconds: Double, direct: Bool, keepALO: Bool, cameraScreen: Bool) -> Never {
    let stats = FrameStats()
    let renderer = FrameRenderer()
    let live = LiveView()
    live.useGPhoto2(preferDirectUSB: direct)
    live.options.turnOffAutoLightingOptimizer = !keepALO
    live.options.showOnCameraScreen = cameraScreen
    var connectedAt: Date?
    live.onEvent = { event in
        switch event {
        case let .connected(model, direct):
            log("\(model) (\(direct ? "direct USB" : "libgphoto2")): measuring for \(Int(seconds))s after the first frame…")
        case let .waiting(reason): log("waiting: \(reason)")
        case let .notice(message): log("note: \(message)")
        case .cameraInUse: log("waiting: another app is using the camera (Photos, Image Capture, EOS Utility…)")
        case let .battery(level): log("camera battery: \(level.text)")
        }
    }
    live.onFrame = { jpeg in
        if connectedAt == nil {
            connectedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let s = stats.take()
                print(String(format: "frames %d, %.1f fps, median gap %.0f ms, max gap %.0f ms",
                             s.frames, s.fps, s.medianMs, s.maxMs))
                live.stop()
                exit(0)
            }
            return
        }
        _ = renderer.render(jpeg: jpeg)  // include conversion cost
        stats.frame()
    }
    live.start()
    runUntilInterrupted { live.stop() }
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
let command = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "run"
if args.first == command { args.removeFirst() }

switch command {
case "run":
    var cameraName = "OBS Virtual Camera"
    var mode = FrameRenderer.Mode.fill
    var exposeOnConnect = false
    var fps = 24.0
    var direct = true
    var keepALO = false
    var cameraScreen = true
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--camera":
            guard i + 1 < args.count else { fail("--camera needs a name") }
            cameraName = args[i + 1]; i += 1
        case "--fit": mode = .fit
        case "--expose": exposeOnConnect = true
        case "--gphoto2": direct = false
        case "--keep-alo": keepALO = true
        case "--no-camera-screen": cameraScreen = false
        case "--fps":
            guard i + 1 < args.count, let value = Double(args[i + 1]), value >= 0, value <= 60 else {
                fail("--fps needs a number from 0 to 60")
            }
            fps = value; i += 1
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    run(cameraName: cameraName, mode: mode, expose: exposeOnConnect, fps: fps, direct: direct, keepALO: keepALO,
        cameraScreen: cameraScreen)
case "check":
    var cameraName = "OBS Virtual Camera"
    var seconds = 15.0
    var cameraScreen = true
    var i = 0
    while i < args.count {
        if args[i] == "--camera", i + 1 < args.count { cameraName = args[i + 1]; i += 1 }
        else if args[i] == "--no-camera-screen" { cameraScreen = false }
        else if let s = Double(args[i]) { seconds = s }
        else { fail("unknown option \(args[i])\n\n\(usage)") }
        i += 1
    }
    check(cameraName: cameraName, seconds: seconds, cameraScreen: cameraScreen)
case "peek":
    var cameraName = "OBS Virtual Camera"
    var seconds = 5.0
    var output = "peek.jpg"
    var i = 0
    while i < args.count {
        if args[i] == "--camera", i + 1 < args.count { cameraName = args[i + 1]; i += 1 }
        else if args[i] == "-o", i + 1 < args.count { output = args[i + 1]; i += 1 }
        else if let s = Double(args[i]) { seconds = s }
        else { fail("unknown option \(args[i])\n\n\(usage)") }
        i += 1
    }
    peek(cameraName: cameraName, seconds: seconds, output: output)
case "cameras": listCameras()
case "info": info()
case "expose": expose()
case "snap": snap(args.first ?? "snap.jpg")
case "bench":
    var seconds = 15.0
    var direct = true
    var keepALO = false
    var cameraScreen = true
    for arg in args {
        if arg == "--gphoto2" { direct = false }
        else if arg == "--keep-alo" { keepALO = true }
        else if arg == "--no-camera-screen" { cameraScreen = false }
        else if let s = Double(arg) { seconds = s }
        else { fail("unknown option \(arg)\n\n\(usage)") }
    }
    bench(seconds: seconds, direct: direct, keepALO: keepALO, cameraScreen: cameraScreen)
case "help", "-h", "--help": print(usage)
default: fail("unknown command \(command)\n\n\(usage)")
}
