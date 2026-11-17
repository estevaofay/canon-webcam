import CanonUSB
import Foundation
import XCTest

/// An error that classifies itself the way LiveView asks.
struct FakeError: CameraConnectionError, CustomStringConvertible {
    var isNoCamera = false
    var isDisconnect = false
    var isUnsupported = false
    var isInUse = false
    var description: String { "fake error" }

    static let noCamera = FakeError(isNoCamera: true)
    static let disconnect = FakeError(isDisconnect: true)
    static let unsupported = FakeError(isUnsupported: true)
    static let inUse = FakeError(isInUse: true)
}

/// Counts cameras that are open at the same time.
final class OpenCounter {
    private let lock = NSLock()
    private var open = 0
    private(set) var maxOpen = 0
    private(set) var opened = 0

    func didOpen() { lock.withLock { open += 1; opened += 1; maxOpen = max(maxOpen, open) } }
    func didClose() { lock.withLock { open -= 1 } }
    var snapshot: (open: Int, maxOpen: Int, opened: Int) { lock.withLock { (open, maxOpen, opened) } }
}

/// A camera that plays a script of frames and errors, then keeps doing
/// `afterwards` (a frame every 5 ms by default).
final class FakeCamera: LiveViewCamera {
    enum Step { case frame, fail(Error), block }

    let model: String
    private let lock = NSLock()
    private var steps: [Step]
    private let afterwards: Step
    private let counter: OpenCounter?
    private var frameNumber: UInt8 = 0
    private var _closeCount = 0
    var closeCount: Int { lock.withLock { _closeCount } }

    init(model: String = "Fake", steps: [Step] = [], afterwards: Step = .frame, counter: OpenCounter? = nil) {
        self.model = model
        self.steps = steps
        self.afterwards = afterwards
        self.counter = counter
        counter?.didOpen()
    }

    func nextFrame() throws -> Data {
        usleep(5_000)
        let step = lock.withLock { steps.isEmpty ? afterwards : steps.removeFirst() }
        switch step {
        case .frame:
            let n = lock.withLock { frameNumber &+= 1; return frameNumber }
            return Data([0xFF, 0xD8, n, 0xFF, 0xD9])
        case let .fail(error):
            throw error
        case .block:
            usleep(200_000)
            throw FakeError(isDisconnect: false)
        }
    }

    func close() {
        lock.withLock { _closeCount += 1 }
        counter?.didClose()
    }
}

/// Collects LiveView events and frames from any thread.
final class Recorder {
    private let lock = NSLock()
    private var _events: [LiveView.Event] = []
    private var _frames: [Data] = []
    var events: [LiveView.Event] { lock.withLock { _events } }
    var frames: [Data] { lock.withLock { _frames } }

    func attach(to live: LiveView) {
        live.onEvent = { [self] event in lock.withLock { _events.append(event) } }
        live.onFrame = { [self] frame in lock.withLock { _frames.append(frame) } }
    }

    /// Polls `condition` until it holds or `timeout` passes.
    @discardableResult
    func wait(_ timeout: TimeInterval = 2, until condition: (Recorder) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(self) { return true }
            usleep(10_000)
        }
        return condition(self)
    }

    func count(where match: (LiveView.Event) -> Bool) -> Int { events.filter(match).count }
}

extension LiveView.Event {
    var isConnected: Bool { if case .connected = self { return true }; return false }
    var waitingReason: String? { if case let .waiting(reason) = self { return reason }; return nil }
}
