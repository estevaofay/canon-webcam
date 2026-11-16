import CanonCapture
import Foundation
import VirtualCamera

let usage = """
canon-webcam: use an old Canon EOS DSLR (Rebel T3i/600D, T5/1200D, ...) as a webcam on macOS.

USAGE
  canon-webcam [run] [--camera NAME] [--fit] [--expose]
      Stream the DSLR's live view into a virtual camera until Ctrl-C.
      --camera NAME  virtual camera to feed (default: "OBS Virtual Camera";
                     use "Canon Webcam" for this project's own extension)
      --fit          show the whole 3:2 frame with side bars (default: crop to 16:9)
      --expose       set 1/60s and ISO Auto on connect (mode dial on M)
  canon-webcam cameras          list virtual cameras that accept frames
  canon-webcam info             show the connected DSLR and its exposure settings
  canon-webcam expose           set webcam-friendly exposure: 1/60s, ISO Auto
  canon-webcam snap [FILE]      save one live-view frame (default: snap.jpg)
  canon-webcam bench [SECONDS]  measure live-view frame rate (default: 15s)

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

/// Runs `body` until Ctrl-C (or until it returns), then calls `cleanup`.
func runUntilInterrupted(cleanup: @escaping () -> Void) -> Never {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
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
    dispatchMain()
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

func setWebcamExposure(_ camera: EOSCamera) throws {
    try camera.setSetting("shutterspeed", "1/60")
    try camera.setSetting("iso", "Auto")
}

// MARK: - Commands

func run(cameraName: String, mode: FrameRenderer.Mode, expose: Bool) -> Never {
    let sink: VirtualCameraSink
    do { sink = try VirtualCameraSink(cameraNamed: cameraName) } catch { fail("\(error)") }
    log("feeding \"\(sink.camera.name)\" (\(mode.rawValue) mode). Ctrl-C to stop.")

    let renderer = FrameRenderer(mode: mode)
    let stats = FrameStats()
    let live = LiveView()
    if expose { live.onConnect = setWebcamExposure }
    live.onEvent = { event in
        switch event {
        case let .connected(model): log("camera connected: \(model), live view on")
        case let .waiting(reason): log("waiting: \(reason)")
        }
    }
    live.onFrame = { jpeg in
        if let frame = renderer.render(jpeg: jpeg) {
            sink.send(frame)
            stats.frame()
        }
    }
    live.start()

    var lastSent = 0
    var lastDropped = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler {
        let s = stats.take()
        guard s.frames > 0 else { return }
        let sent = sink.sent - lastSent, dropped = sink.dropped - lastDropped
        lastSent = sink.sent; lastDropped = sink.dropped
        log(String(format: "%.1f fps (median gap %.0f ms, max %.0f ms), sent %d, dropped %d",
                   s.fps, s.medianMs, s.maxMs, sent, dropped))
    }
    timer.resume()

    runUntilInterrupted {
        timer.cancel()
        live.stop()
        sink.stop()
    }
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

func bench(seconds: Double) -> Never {
    let stats = FrameStats()
    let renderer = FrameRenderer()
    let live = LiveView()
    var connectedAt: Date?
    live.onEvent = { event in
        switch event {
        case let .connected(model):
            log("\(model): measuring for \(Int(seconds))s after the first frame…")
        case let .waiting(reason): log("waiting: \(reason)")
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
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--camera":
            guard i + 1 < args.count else { fail("--camera needs a name") }
            cameraName = args[i + 1]; i += 1
        case "--fit": mode = .fit
        case "--expose": exposeOnConnect = true
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    run(cameraName: cameraName, mode: mode, expose: exposeOnConnect)
case "cameras": listCameras()
case "info": info()
case "expose": expose()
case "snap": snap(args.first ?? "snap.jpg")
case "bench": bench(seconds: args.first.flatMap(Double.init) ?? 15)
case "help", "-h", "--help": print(usage)
default: fail("unknown command \(command)\n\n\(usage)")
}
