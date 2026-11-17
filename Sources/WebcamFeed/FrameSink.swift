import CoreVideo
import Foundation
import VirtualCamera

/// Where frames go: a virtual camera's input (or a fake one in tests).
public protocol FrameSink: AnyObject {
    func send(_ frame: CVPixelBuffer)
    var sent: Int { get }
    var dropped: Int { get }
    func stop()
}

extension VirtualCameraSink: FrameSink {}

/// The current connection to the virtual camera. Camera extensions can restart
/// (another app quits, macOS relaunches them), which silently strands an open
/// sink; the feed swaps in a fresh one when that happens.
final class SinkConnection {
    let cameraName: String
    private let opener: (String) throws -> FrameSink
    private let lock = NSLock()
    private var sink: FrameSink?
    private var sentBefore = 0
    private var droppedBefore = 0

    init(cameraName: String, opener: @escaping (String) throws -> FrameSink) {
        self.cameraName = cameraName
        self.opener = opener
    }

    var isOpen: Bool { lock.withLock { sink != nil } }
    /// Totals across reconnections.
    var sent: Int { lock.withLock { sentBefore + (sink?.sent ?? 0) } }
    var dropped: Int { lock.withLock { droppedBefore + (sink?.dropped ?? 0) } }

    func send(_ frame: CVPixelBuffer) { lock.withLock { sink?.send(frame) } }

    func open() throws {
        let new = try opener(cameraName)
        lock.withLock { sink = new }
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
