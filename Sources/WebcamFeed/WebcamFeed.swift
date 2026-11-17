import AVFoundation
import CanonUSB
import CoreVideo
import Foundation
import VirtualCamera

/// What the feed sends, and how it treats the camera.
public struct FeedSettings: Equatable {
    /// The virtual camera to feed.
    public var cameraName = "OBS Virtual Camera"
    /// 0 (the default) sends each camera frame to video apps as it arrives:
    /// the camera's own rate, nothing added. N sends a steady N per second,
    /// repeating the newest camera frame when the next isn't ready.
    public var outputFPS: Double = 0
    public var mode: FrameRenderer.Mode = .fill
    public var liveView = LiveViewOptions()

    public init() {}
}

/// Something that stops the feed from reaching video apps.
public enum FeedProblem: Equatable {
    /// The virtual camera isn't installed, or its extension isn't allowed.
    case virtualCameraMissing(name: String)
    /// macOS doesn't allow this app to use cameras (virtual ones included).
    case cameraAccessDenied
    /// Another app (Photos, Image Capture, EOS Utility…) holds the DSLR.
    case cameraInUse
}

public enum FeedStatus: Equatable {
    case stopped
    case waitingForCamera(reason: String)
    case live(model: String)
    case problem(FeedProblem)
}

/// Streams the DSLR's live view into a virtual camera: frames in from
/// `LiveView`, frames out to video apps, reconnecting to either side when it
/// goes away. Shared by the command-line tool and the menu bar app.
/// Thread-safe: state is behind a lock, so `start`/`stop` can run on any queue
/// (set `onChange`/`onLog` before starting).
public final class WebcamFeed: @unchecked Sendable {
    public private(set) var settings: FeedSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }
    public var status: FeedStatus { lock.withLock { _status } }
    public var battery: BatteryLevel? { lock.withLock { _battery } }
    /// Frames actually sent to the virtual camera per second, over the last 2 s.
    public var sentFPS: Double { lock.withLock { _sentFPS } }
    /// Why the virtual camera couldn't be opened, if it couldn't.
    public var sinkError: Error? { lock.withLock { _sinkError } }

    /// Called on the main queue after `status`, `battery` or `sentFPS` change.
    public var onChange: () -> Void = {}
    /// Progress messages, worded for a log (the CLI prints them).
    public var onLog: (String) -> Void = { _ in }

    private let liveView: LiveView
    private let connection: SinkConnection
    private let cameraAccess: () -> Bool
    private let renderer: FrameRenderer
    private let latest = LatestFrame()
    private let stats = FrameStats()

    private let lock = NSLock()
    private var _settings: FeedSettings
    private var _status = FeedStatus.stopped
    private var _battery: BatteryLevel?
    private var _sentFPS = 0.0
    private var _sinkError: Error?
    private var running = false
    private var accessDenied = false
    private var cameraState = FeedStatus.waitingForCamera(reason: "looking for a camera")
    private var sinkProblem: FeedProblem?
    private var cameraFrames = 0

    private let control = DispatchQueue(label: "canon-webcam.feed")
    private let output = DispatchQueue(label: "canon-webcam.output", qos: .userInteractive)
    private var timers: [DispatchSourceTimer] = []

    public init(
        settings: FeedSettings,
        liveView: LiveView = LiveView(),
        openSink: @escaping (String) throws -> FrameSink = { try VirtualCameraSink(cameraNamed: $0) },
        cameraAccess: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    ) {
        _settings = settings
        self.liveView = liveView
        self.cameraAccess = cameraAccess
        connection = SinkConnection(cameraName: settings.cameraName, opener: openSink)
        renderer = FrameRenderer(mode: settings.mode)
        liveView.options = settings.liveView
        liveView.onEvent = { [weak self] in self?.handle($0) }
        liveView.onFrame = { [weak self] in self?.frame($0) }
    }

    // MARK: Starting and stopping

    /// Starts streaming. Without camera access it only reports the problem.
    public func start() {
        guard lock.withLock({ !running }) else { return }
        guard cameraAccess() else {
            update { $0.accessDenied = true }
            return
        }
        update {
            $0.running = true
            $0.accessDenied = false
            $0.cameraState = .waitingForCamera(reason: "looking for a camera")
            $0._battery = nil
            $0._sentFPS = 0
        }
        openSink()
        liveView.start()
        startTimers()
    }

    /// Stops streaming, closes the camera (live view off, settings restored,
    /// USB released) and the virtual camera. Blocks until done; safe to call twice.
    public func stop() {
        let wasRunning = lock.withLock { () -> Bool in defer { running = false }; return running }
        if wasRunning {
            control.sync {
                timers.forEach { $0.cancel() }
                timers.removeAll()
            }
            liveView.stop()
            connection.close()
            latest.clear()
        }
        update {
            $0.sinkProblem = nil
            $0.accessDenied = false
            $0._battery = nil
            $0._sentFPS = 0
        }
    }

    /// Shows live view on the camera's own screen too, or not. Applied at once
    /// when streaming (live view restarts, about a second).
    public func setShowOnCameraScreen(_ on: Bool) {
        settings.liveView.showOnCameraScreen = on
        liveView.options = settings.liveView
        guard lock.withLock({ running }) else { return }
        liveView.stop()
        liveView.start()
    }

    /// The newest frame sent to video apps (at most a second old), for a preview.
    public func latestFrame() -> CVPixelBuffer? { latest.get(maxAge: 1) }

    // MARK: Camera side

    private func handle(_ event: LiveView.Event) {
        switch event {
        case let .connected(model, direct):
            onLog("camera connected: \(model), live view on (\(direct ? "direct USB" : "libgphoto2"))")
            update { $0.cameraState = .live(model: model) }
        case let .waiting(reason):
            onLog("waiting: \(reason)")
            update { $0.cameraState = .waitingForCamera(reason: reason); $0._battery = nil }
        case .cameraInUse:
            onLog("waiting: another app is using the camera (Photos, Image Capture, EOS Utility…)")
            update { $0.cameraState = .problem(.cameraInUse) }
        case let .notice(message):
            onLog("note: \(message)")
        case let .battery(level):
            onLog("camera battery: \(level.text)")
            update { $0._battery = level }
        }
    }

    private func frame(_ jpeg: Data) {
        lock.withLock { cameraFrames += 1 }
        guard let frame = renderer.render(jpeg: jpeg) else { return }
        if settings.outputFPS > 0 { latest.set(frame) } else { latest.set(frame); connection.send(frame) }
        stats.frame()
    }

    // MARK: Virtual camera side

    private func openSink() {
        do {
            try connection.open()
            update { $0.sinkProblem = nil; $0._sinkError = nil }
        } catch {
            update {
                $0.sinkProblem = .virtualCameraMissing(name: $0._settings.cameraName)
                $0._sinkError = error
            }
        }
    }

    private func startTimers() {
        let name = settings.cameraName
        let fps = settings.outputFPS

        // Output clock (--fps N): video apps get frames at a steady rate. When the camera
        // hasn't produced a new frame yet, the newest one is sent again; after a
        // second without frames (camera stalled or unplugged) nothing is sent.
        var all: [DispatchSourceTimer] = []
        if fps > 0 {
            let clock = DispatchSource.makeTimerSource(flags: .strict, queue: output)
            clock.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
            clock.setEventHandler { [weak self] in
                guard let self, let frame = self.latest.get(maxAge: 1) else { return }
                self.connection.send(frame)
            }
            all.append(clock)
        }

        // Watchdog: reopen the virtual camera when it's missing, or when the
        // camera keeps delivering but the virtual camera stopped taking frames
        // for ~2 s (its extension restarted, or something else took over its
        // input). Also measures the frame rate actually sent.
        var watchFrames = lock.withLock { cameraFrames }
        var watchSent = connection.sent
        let watchdog = DispatchSource.makeTimerSource(queue: control)
        watchdog.schedule(deadline: .now() + 2, repeating: 2)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            let frames = self.lock.withLock { self.cameraFrames }
            let sent = self.connection.sent
            self.update { $0._sentFPS = Double(sent - watchSent) / 2 }
            defer { watchFrames = frames; watchSent = sent }
            if !self.connection.isOpen {
                self.openSink()
                if self.connection.isOpen { self.onLog("connected to \"\(name)\"") }
                return
            }
            if frames - watchFrames >= 5 && sent == watchSent {
                self.onLog("\"\(name)\" stopped taking frames (its extension restarted, or another app "
                    + "such as OBS started feeding it); reconnecting")
                self.connection.close()
                self.openSink()
                self.onLog(self.connection.isOpen ? "reconnected to \"\(name)\"" : "waiting for \"\(name)\" to come back")
            }
        }
        all.append(watchdog)

        var lastSent = connection.sent
        var lastDropped = connection.dropped
        let report = DispatchSource.makeTimerSource(queue: control)
        report.schedule(deadline: .now() + 10, repeating: 10)
        report.setEventHandler { [weak self] in
            guard let self else { return }
            let s = self.stats.take()
            let sent = self.connection.sent - lastSent, dropped = self.connection.dropped - lastDropped
            lastSent = self.connection.sent
            lastDropped = self.connection.dropped
            guard s.frames > 0 else { return }
            self.onLog(String(format: "%.1f fps from camera (median gap %.0f ms, max %.0f ms), sent %.1f fps, dropped %d",
                              s.fps, s.medianMs, s.maxMs, Double(sent) / 10, dropped))
        }
        all.append(report)

        control.sync { timers = all }
        all.forEach { $0.resume() }
    }

    // MARK: State

    /// Changes state under the lock, recomputes `status`, and tells `onChange`
    /// when anything visible changed.
    private func update(_ change: (WebcamFeed) -> Void) {
        let changed = lock.withLock { () -> Bool in
            let before = (_status, _battery, _sentFPS)
            change(self)
            if running {
                _status = sinkProblem.map { .problem($0) } ?? cameraState
            } else {
                _status = accessDenied ? .problem(.cameraAccessDenied) : .stopped
            }
            return before.0 != _status || before.1 != _battery || before.2 != _sentFPS
        }
        if changed { DispatchQueue.main.async { [weak self] in self?.onChange() } }
    }
}
