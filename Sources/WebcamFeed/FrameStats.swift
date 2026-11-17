import CoreVideo
import Foundation

/// Frame timing, for the periodic stats log line and `bench`.
public final class FrameStats {
    private let lock = NSLock()
    private var frames = 0
    private var gaps: [Double] = []
    private var last: Date?

    public init() {}

    public func frame() {
        lock.withLock {
            let now = Date()
            if let last { gaps.append(now.timeIntervalSince(last)) }
            last = now
            frames += 1
        }
    }

    /// Returns (fps, median gap ms, max gap ms) since the last call, and resets.
    public func take() -> (fps: Double, medianMs: Double, maxMs: Double, frames: Int) {
        lock.withLock {
            defer { gaps.removeAll(keepingCapacity: true); frames = 0 }
            guard !gaps.isEmpty else { return (0, 0, 0, frames) }
            let sorted = gaps.sorted()
            let total = gaps.reduce(0, +)
            return (Double(gaps.count) / total, sorted[sorted.count / 2] * 1000, sorted.last! * 1000, frames)
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

    func clear() { lock.withLock { frame = nil; arrived = .distantPast } }
}
