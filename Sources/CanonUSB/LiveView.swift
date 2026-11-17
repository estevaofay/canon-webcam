import Foundation

/// Something that streams live-view JPEGs from a connected camera.
public protocol LiveViewCamera: AnyObject {
    var model: String { get }
    func nextFrame() throws -> Data
    func close()
}

/// How a camera error should be handled by the live-view loop.
public protocol CameraConnectionError: Error {
    /// No camera is connected.
    var isNoCamera: Bool { get }
    /// The camera went away (unplugged, switched off, stopped answering).
    var isDisconnect: Bool { get }
    /// This connector can't stream this camera; try the fallback.
    var isUnsupported: Bool { get }
    /// Another app holds the camera.
    var isInUse: Bool { get }
}

/// What to do with the camera while streaming.
public struct LiveViewOptions: Equatable {
    /// Switch Auto Lighting Optimizer off while streaming (much faster live
    /// view on some bodies) and restore it afterwards.
    public var turnOffAutoLightingOptimizer = true
    /// Show live view on the camera's own screen as well as sending it to the
    /// computer.
    public var showOnCameraScreen = true

    public init() {}
}

extension DirectLiveView: LiveViewCamera {}

/// Pulls live-view frames from the camera on a background thread, forever,
/// reconnecting whenever the camera disappears or errors out.
public final class LiveView {
    public enum Event: Equatable {
        /// `direct` is true when frames come over the fast direct-USB path,
        /// false when they come through the fallback (libgphoto2).
        case connected(model: String, direct: Bool)
        case waiting(reason: String)
        /// Another app holds the camera; retrying.
        case cameraInUse
        /// Streaming works, but something is worth telling the user.
        case notice(String)
        /// The camera's battery level, after connecting and when it changes.
        case battery(BatteryLevel)
    }

    /// Opens a camera and starts live view. Defaults to Canon EOS over USB.
    public var connect: (LiveViewOptions) throws -> LiveViewCamera
    /// Whether cameras from `connect` use the direct USB path (for `.connected`).
    public var connectIsDirect = true
    /// Used after `connect` throws an `isUnsupported` error, e.g. libgphoto2
    /// for cameras that aren't Canon EOS.
    public var fallback: ((LiveViewOptions) throws -> LiveViewCamera)?

    /// Read when (re)connecting.
    public var options: LiveViewOptions {
        get { lock.withLock { _options } }
        set { lock.withLock { _options = newValue } }
    }
    private var _options = LiveViewOptions()

    /// Called on a delivery thread with every JPEG frame. The capture thread
    /// hands frames over and immediately asks the camera for the next one; if
    /// `onFrame` is still busy with the previous frame, the new one replaces
    /// any frame still waiting, so slow consumers see the newest frame.
    public var onFrame: (Data) -> Void = { _ in }
    /// Called on the capture thread when the connection state changes.
    public var onEvent: (Event) -> Void = { _ in }

    public init(connect: @escaping (LiveViewOptions) throws -> LiveViewCamera = { try DirectLiveView(options: $0) }) {
        self.connect = connect
    }

    // MARK: Frame delivery

    private let delivery = DispatchQueue(label: "canon-webcam.frames", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: Data?

    private func deliver(_ jpeg: Data) {
        let schedule = pendingLock.withLock { () -> Bool in
            defer { pending = jpeg }
            return pending == nil
        }
        guard schedule else { return }
        delivery.async { [weak self] in
            guard let self else { return }
            while let frame = self.pendingLock.withLock({ () -> Data? in
                defer { self.pending = nil }
                return self.pending
            }) {
                self.onFrame(frame)
                if self.pendingLock.withLock({ self.pending == nil }) { break }
            }
        }
    }

    // MARK: Running

    private let lock = NSLock()
    /// One flag per run, so a capture thread from an earlier run that is still
    /// winding down can't be revived by a later `start()`.
    private final class Run {
        private let lock = NSLock()
        private var stopped = false
        let finished = DispatchSemaphore(value: 0)
        var isStopped: Bool { lock.withLock { stopped } }
        func stop() { lock.withLock { stopped = true } }
    }
    private var current: Run?

    /// Starts capturing on a background thread. Does nothing if already running.
    public func start() {
        let run = Run()
        let started = lock.withLock { () -> Bool in
            guard current == nil else { return false }
            current = run
            return true
        }
        guard started else { return }
        let thread = Thread { [weak self] in
            defer { run.finished.signal() }
            self?.capture(run)
        }
        thread.name = "canon-webcam.liveview"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops capturing and waits (up to 5 s) until the camera is closed:
    /// live view off, settings restored, USB released. Safe to call twice.
    public func stop() {
        guard let run = lock.withLock({ () -> Run? in defer { current = nil }; return current }) else { return }
        run.stop()
        _ = run.finished.wait(timeout: .now() + 5)
    }

    private func capture(_ run: Run) {
        var lastReason = ""
        var useFallback = false
        while !run.isStopped {
            let camera: LiveViewCamera
            let direct: Bool
            do {
                if useFallback, let fallback {
                    camera = try fallback(options)
                    direct = false
                } else {
                    camera = try connect(options)
                    direct = connectIsDirect
                }
            } catch let error as CameraConnectionError where error.isUnsupported && !useFallback && fallback != nil {
                useFallback = true
                continue
            } catch {
                let connectionError = error as? CameraConnectionError
                if connectionError?.isInUse == true {
                    if lastReason != "in use" { onEvent(.cameraInUse); lastReason = "in use" }
                } else {
                    let reason = connectionError?.isNoCamera == true
                        ? "no camera found: plug it in over USB and switch it on"
                        : "\(error)"
                    if reason != lastReason { onEvent(.waiting(reason: reason)); lastReason = reason }
                }
                sleep(2, unless: run)
                continue
            }
            if run.isStopped { camera.close(); break }
            onEvent(.connected(model: camera.model, direct: direct))
            if let problem = (camera as? DirectLiveView)?.autoLightingOptimizerProblem { onEvent(.notice(problem)) }
            lastReason = ""

            let usbCamera = camera as? DirectLiveView
            var battery: BatteryLevel?
            var failures = 0
            while !run.isStopped {
                do {
                    let jpeg = try camera.nextFrame()
                    failures = 0
                    deliver(jpeg)
                    if let level = usbCamera?.battery, level != battery {
                        battery = level
                        onEvent(.battery(level))
                    }
                } catch {
                    // Busy/transient errors happen while the camera autofocuses or
                    // meters; give it a few tries before reconnecting.
                    failures += 1
                    let disconnected = (error as? CameraConnectionError)?.isDisconnect == true
                    if failures >= 10 || disconnected {
                        onEvent(.waiting(reason: "lost camera (\(error)), reconnecting"))
                        break
                    }
                    usleep(50_000)
                }
            }
            camera.close()
            if !run.isStopped { sleep(1, unless: run) }
        }
    }

    private func sleep(_ seconds: Double, unless run: Run) {
        let end = Date().addingTimeInterval(seconds)
        while !run.isStopped && Date() < end { usleep(20_000) }
    }
}
