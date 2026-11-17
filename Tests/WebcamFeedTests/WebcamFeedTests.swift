import CanonUSB
import CoreImage
import CoreVideo
import Foundation
import VirtualCamera
import WebcamFeed
import XCTest

/// Records what the feed sends instead of feeding a real virtual camera.
final class FakeSink: FrameSink {
    private let lock = NSLock()
    private var _sent = 0
    private var _stopped = false
    var sent: Int { lock.withLock { _sent } }
    var dropped: Int { 0 }
    var stopped: Bool { lock.withLock { _stopped } }
    func send(_ frame: CVPixelBuffer) { lock.withLock { _sent += 1 } }
    func stop() { lock.withLock { _stopped = true } }
}

/// A real 1056x704 JPEG-sized frame isn't needed: FrameRenderer decodes
/// whatever the fake camera sends, so the fake camera sends a tiny real JPEG.
private let tinyJPEG: Data = {
    let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
    return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB())!
}()

/// A camera that streams `tinyJPEG` (FakeCamera's frames aren't decodable).
final class JPEGCamera: LiveViewCamera {
    let model = "Fake"
    private let lock = NSLock()
    private var remaining: Int?
    private var _closeCount = 0
    var closeCount: Int { lock.withLock { _closeCount } }

    /// `frames`: how many frames before it disconnects (nil = forever).
    init(frames: Int? = nil) { remaining = frames }

    func nextFrame() throws -> Data {
        usleep(30_000)
        let left = lock.withLock { () -> Int? in
            if let r = remaining { remaining = r - 1 }
            return remaining
        }
        if let left, left < 0 { throw FakeError.disconnect }
        return tinyJPEG
    }

    func close() { lock.withLock { _closeCount += 1 } }
}

final class WebcamFeedTests: XCTestCase {
    private func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    func testAccessDeniedNeverStartsLiveView() {
        var connects = 0
        let live = LiveView(connect: { _ in connects += 1; return JPEGCamera() })
        let feed = WebcamFeed(settings: FeedSettings(), liveView: live,
                              openSink: { _ in FakeSink() }, cameraAccess: { false })
        feed.start()
        defer { feed.stop() }

        XCTAssertEqual(feed.status, .problem(.cameraAccessDenied))
        usleep(300_000)
        XCTAssertEqual(connects, 0)
    }

    func testMissingVirtualCameraRecovers() {
        let sink = FakeSink()
        let lock = NSLock()
        var attempts = 0
        let feed = WebcamFeed(
            settings: FeedSettings(), liveView: LiveView(connect: { _ in JPEGCamera() }),
            openSink: { name in
                let n = lock.withLock { attempts += 1; return attempts }
                if n <= 2 { throw VirtualCameraError.notFound(name: name, available: []) }
                return sink
            },
            cameraAccess: { true })
        feed.start()
        defer { feed.stop() }

        XCTAssertEqual(feed.status, .problem(.virtualCameraMissing(name: "OBS Virtual Camera")))
        XCTAssertTrue(wait(6) { feed.status == .live(model: "Fake") })
        XCTAssertTrue(wait(1) { sink.sent > 0 })
    }

    func testStatusFollowsCamera() {
        let lock = NSLock()
        var connects = 0
        let live = LiveView(connect: { _ in
            let n = lock.withLock { connects += 1; return connects }
            if n == 1 { return JPEGCamera(frames: 10) }
            throw FakeError.noCamera
        })
        let feed = WebcamFeed(settings: FeedSettings(), liveView: live,
                              openSink: { _ in FakeSink() }, cameraAccess: { true })
        feed.start()
        defer { feed.stop() }

        XCTAssertTrue(wait(2) { feed.status == .live(model: "Fake") })
        XCTAssertTrue(wait(3) {
            if case .waitingForCamera = feed.status { return true }
            return false
        })
    }

    func testSteadyOutputRepeatsNewestFrame() {
        let sink = FakeSink()
        let lock = NSLock()
        var connects = 0
        let live = LiveView(connect: { _ in
            let n = lock.withLock { connects += 1; return connects }
            if n == 1 { return JPEGCamera(frames: 1) }
            throw FakeError.noCamera
        })
        let feed = WebcamFeed(settings: FeedSettings(), liveView: live, openSink: { _ in sink }, cameraAccess: { true })
        feed.start()
        defer { feed.stop() }

        XCTAssertTrue(wait(2) { sink.sent > 0 })
        let start = sink.sent
        usleep(1_000_000)
        let inOneSecond = sink.sent - start
        // The camera sent one frame; the clock keeps resending it at 24 fps
        // until it is a second old, then stops.
        XCTAssertTrue((10...26).contains(inOneSecond), "sent \(inOneSecond) in 1 s")
        usleep(500_000)
        let later = sink.sent
        usleep(500_000)
        XCTAssertEqual(sink.sent, later, "kept sending a stale frame")
    }

    func testStopStopsLiveViewAndClosesSink() {
        let camera = JPEGCamera()
        let sink = FakeSink()
        let feed = WebcamFeed(settings: FeedSettings(), liveView: LiveView(connect: { _ in camera }),
                              openSink: { _ in sink }, cameraAccess: { true })
        feed.start()
        XCTAssertTrue(wait(2) { feed.status == .live(model: "Fake") })

        feed.stop()
        XCTAssertEqual(camera.closeCount, 1)
        XCTAssertTrue(sink.stopped)
        XCTAssertEqual(feed.status, .stopped)
        feed.stop()
        XCTAssertEqual(camera.closeCount, 1)
    }

    func testCameraInUseIsAProblem() {
        let feed = WebcamFeed(settings: FeedSettings(), liveView: LiveView(connect: { _ in throw FakeError.inUse }),
                              openSink: { _ in FakeSink() }, cameraAccess: { true })
        feed.start()
        defer { feed.stop() }
        XCTAssertTrue(wait(2) { feed.status == .problem(.cameraInUse) })
    }
}
