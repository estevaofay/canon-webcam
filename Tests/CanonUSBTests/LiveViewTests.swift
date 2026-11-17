import CanonUSB
import Foundation
import XCTest

final class LiveViewTests: XCTestCase {
    func testWaitsWhenNoCamera() {
        let live = LiveView(connect: { _ in throw FakeError.noCamera })
        let recorder = Recorder()
        recorder.attach(to: live)
        live.start()
        defer { live.stop() }

        XCTAssertTrue(recorder.wait { !$0.events.isEmpty })
        XCTAssertTrue(recorder.events.first?.waitingReason?.contains("no camera found") == true)
        XCTAssertTrue(recorder.frames.isEmpty)
    }

    func testDeliversFrames() {
        let live = LiveView(connect: { _ in FakeCamera(steps: [.frame, .frame, .frame], afterwards: .block) })
        let recorder = Recorder()
        recorder.attach(to: live)
        live.start()
        defer { live.stop() }

        XCTAssertTrue(recorder.wait(1) { !$0.frames.isEmpty })
        XCTAssertEqual(recorder.events.first, .connected(model: "Fake", direct: true))
    }

    func testDisconnectReconnects() {
        let first = FakeCamera(steps: [.frame, .frame, .fail(FakeError.disconnect)], afterwards: .block)
        let lock = NSLock()
        var connects = 0
        let live = LiveView(connect: { _ in
            let n = lock.withLock { connects += 1; return connects }
            return n == 1 ? first : FakeCamera()
        })
        let recorder = Recorder()
        recorder.attach(to: live)
        live.start()
        defer { live.stop() }

        XCTAssertTrue(recorder.wait(4) { $0.count(where: \.isConnected) >= 2 })
        XCTAssertEqual(recorder.count { $0.waitingReason?.contains("lost camera") == true }, 1)
        XCTAssertEqual(first.closeCount, 1)
    }

    func testStopClosesCameraBeforeReturning() {
        let camera = FakeCamera()
        let live = LiveView(connect: { _ in camera })
        let recorder = Recorder()
        recorder.attach(to: live)
        live.start()
        XCTAssertTrue(recorder.wait { $0.count(where: \.isConnected) == 1 })

        live.stop()
        XCTAssertEqual(camera.closeCount, 1)
    }

    func testRestartNeverOverlapsCameras() {
        let counter = OpenCounter()
        let live = LiveView(connect: { _ in FakeCamera(counter: counter) })
        for _ in 0..<5 {
            live.start()
            usleep(30_000)
            live.stop()
        }
        let snapshot = counter.snapshot
        XCTAssertEqual(snapshot.maxOpen, 1)
        XCTAssertEqual(snapshot.open, 0)
        XCTAssertGreaterThanOrEqual(snapshot.opened, 1)
    }

    func testInUseReportsCameraInUse() {
        let live = LiveView(connect: { _ in throw FakeError.inUse })
        let recorder = Recorder()
        recorder.attach(to: live)
        live.start()
        defer { live.stop() }

        XCTAssertTrue(recorder.wait { !$0.events.isEmpty })
        XCTAssertEqual(recorder.events.first, .cameraInUse)
        XCTAssertNil(recorder.events.first { $0.waitingReason != nil })
    }

    func testUnsupportedUsesFallback() {
        let live = LiveView(connect: { _ in throw FakeError.unsupported })
        live.fallback = { _ in FakeCamera(model: "Other") }
        let recorder = Recorder()
        recorder.attach(to: live)
        live.start()
        defer { live.stop() }

        XCTAssertTrue(recorder.wait { !$0.frames.isEmpty })
        XCTAssertEqual(recorder.events.first, .connected(model: "Other", direct: false))
    }
}
