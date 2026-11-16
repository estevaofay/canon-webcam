import CGPhoto2
import Foundation

/// Something that streams live-view JPEGs from a connected camera.
protocol LiveViewCamera: AnyObject {
    var model: String { get }
    func nextFrame() throws -> Data
    func close()
}

extension DirectLiveView: LiveViewCamera {}

extension EOSCamera: LiveViewCamera {
    func nextFrame() throws -> Data { try capturePreview() }
}

/// Pulls live-view frames from the camera on a background thread, forever,
/// reconnecting whenever the camera disappears or errors out.
public final class LiveView {
    public enum Event {
        /// `direct` is true when frames come over the fast direct-USB path,
        /// false when they come through libgphoto2.
        case connected(model: String, direct: Bool)
        case waiting(reason: String)
    }

    /// Use the fast direct-USB live view for Canon EOS cameras (about 21 fps on
    /// a Rebel T5, against about 14 through libgphoto2). Other cameras, and
    /// Canon models without EOS live view, always use libgphoto2.
    public var preferDirectUSB = true

    /// On the direct-USB path, switch the camera's Auto Lighting Optimizer off
    /// while streaming (much faster live view) and restore it afterwards.
    public var turnOffAutoLightingOptimizer = true

    /// Called on a delivery thread with every JPEG frame. The capture thread
    /// hands frames over and immediately asks the camera for the next one; if
    /// `onFrame` is still busy with the previous frame, the new one replaces
    /// any frame still waiting, so slow consumers see the newest frame.
    public var onFrame: (Data) -> Void = { _ in }

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
                // Loop in case a newer frame arrived while handling this one.
                if self.pendingLock.withLock({ self.pending == nil }) { break }
            }
        }
    }

    /// Called on the capture thread when the connection state changes.
    public var onEvent: (Event) -> Void = { _ in }
    /// Applied once after each (re)connection, e.g. to set exposure. Settings
    /// go through libgphoto2, before live view starts.
    public var onConnect: ((EOSCamera) throws -> Void)?

    private let lock = NSLock()
    private var stopRequested = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    public init() {}

    public func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "canon-webcam.liveview"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops capturing, lowers the mirror and releases the camera.
    public func stop() {
        lock.withLock { stopRequested = true }
        if thread != nil { _ = finished.wait(timeout: .now() + 5) }
    }

    private var shouldStop: Bool { lock.withLock { stopRequested } }

    private func run() {
        defer { finished.signal() }
        var lastReason = ""
        var directUnsupported = false
        while !shouldStop {
            let camera: LiveViewCamera
            do {
                camera = try connect(direct: preferDirectUSB && !directUnsupported)
            } catch let error as PTPError where error.kind.isUnsupported {
                // Not a Canon EOS: libgphoto2 knows many more cameras.
                directUnsupported = true
                continue
            } catch {
                let reason = Self.isNoCamera(error)
                    ? "no camera found: plug it in over USB and switch it on"
                    : "\(error)"
                if reason != lastReason { onEvent(.waiting(reason: reason)); lastReason = reason }
                sleepUnlessStopped(2)
                continue
            }
            onEvent(.connected(model: camera.model, direct: camera is DirectLiveView))
            lastReason = ""

            var failures = 0
            while !shouldStop {
                do {
                    let jpeg = try camera.nextFrame()
                    failures = 0
                    deliver(jpeg)
                } catch {
                    // Busy/transient errors happen while the camera autofocuses or
                    // meters; give it a few tries before reconnecting.
                    failures += 1
                    let disconnected = (error as? CameraError)?.isDisconnect == true
                        || (error as? PTPError)?.isDisconnect == true
                    if failures >= 10 || disconnected {
                        onEvent(.waiting(reason: "lost camera (\(error)), reconnecting"))
                        break
                    }
                    usleep(50_000)
                }
            }
            camera.close()
            if !shouldStop { sleepUnlessStopped(1) }
        }
    }

    /// Connects, applies `onConnect`, and starts live view.
    private func connect(direct: Bool) throws -> LiveViewCamera {
        if direct {
            if let onConnect {
                // Apply settings through libgphoto2 first, then hand over.
                let camera = try EOSCamera()
                do { try onConnect(camera) } catch { onEvent(.waiting(reason: "\(error)")) }
                camera.close()
            }
            return try DirectLiveView(turnOffAutoLightingOptimizer: turnOffAutoLightingOptimizer)
        }
        let camera = try EOSCamera()
        guard camera.supportsLiveView else {
            camera.close()
            sleepUnlessStopped(3)
            throw CameraError(code: GP_ERROR_NOT_SUPPORTED, action: "\(camera.model) live view (not supported by libgphoto2)")
        }
        if let onConnect {
            do { try onConnect(camera) } catch { onEvent(.waiting(reason: "\(error)")) }
        }
        return camera
    }

    private static func isNoCamera(_ error: Error) -> Bool {
        if let error = error as? CameraError { return error.code == GP_ERROR_MODEL_NOT_FOUND }
        if let error = error as? PTPError, case .noCamera = error.kind { return true }
        return false
    }

    private func sleepUnlessStopped(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while !shouldStop && Date() < end { usleep(100_000) }
    }
}
