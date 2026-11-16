import Foundation

/// Pulls live-view frames from the camera on a background thread, forever,
/// reconnecting whenever the camera disappears or errors out.
public final class LiveView {
    public enum Event {
        case connected(model: String)
        case waiting(reason: String)
    }

    /// Called on the capture thread with every JPEG frame.
    public var onFrame: (Data) -> Void = { _ in }
    /// Called on the capture thread when the connection state changes.
    public var onEvent: (Event) -> Void = { _ in }
    /// Applied once after each (re)connection, e.g. to set exposure.
    public var onConnect: (EOSCamera) throws -> Void = { _ in }

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
        while !shouldStop {
            let camera: EOSCamera
            do {
                camera = try EOSCamera()
            } catch {
                let reason = (error as? CameraError)?.code == -105
                    ? "no camera found: plug it in over USB and switch it on"
                    : "\(error)"
                if reason != lastReason { onEvent(.waiting(reason: reason)); lastReason = reason }
                sleepUnlessStopped(2)
                continue
            }
            guard camera.supportsLiveView else {
                onEvent(.waiting(reason: "\(camera.model) has no live view support in libgphoto2"))
                camera.close()
                sleepUnlessStopped(5)
                continue
            }
            do { try onConnect(camera) } catch { onEvent(.waiting(reason: "\(error)")) }
            onEvent(.connected(model: camera.model))
            lastReason = ""

            var failures = 0
            while !shouldStop {
                do {
                    let jpeg = try camera.capturePreview()
                    failures = 0
                    onFrame(jpeg)
                } catch {
                    // Busy/transient errors happen while the camera autofocuses or
                    // meters; give it a few tries before reconnecting.
                    failures += 1
                    if failures >= 10 || (error as? CameraError)?.isDisconnect == true {
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

    private func sleepUnlessStopped(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while !shouldStop && Date() < end { usleep(100_000) }
    }
}
