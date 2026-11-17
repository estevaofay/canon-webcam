import CanonUSB
import Foundation
import XCTest

final class CanonEventsTests: XCTestCase {
    /// Little-endian u32 words as bytes.
    private func bytes(_ words: [UInt32]) -> Data {
        var data = Data()
        for word in words { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    func testPropertyValuesParsesPropertyChanges() {
        let data = bytes([16, 0xC189, 0xD1C1, 3,
                          12, 0xC18A, 0xD1B0,
                          16, 0xC189, 0xD111, 4,
                          8, 0])
        XCTAssertEqual(CanonEvents.propertyValues(in: data), [0xD1C1: 3, 0xD111: 4])
    }

    func testPropertyValuesStopsAtTruncatedRecord() {
        let data = bytes([16, 0xC189, 0xD1C1, 3]) + bytes([40, 0xC189]) + Data([1, 2])
        XCTAssertEqual(CanonEvents.propertyValues(in: data), [0xD1C1: 3])
    }

    func testBatteryLevelMapping() {
        XCTAssertEqual([0, 5, 1, 4, 2].map { BatteryLevel(canonValue: $0) },
                       [.low, .quarter, .half, .threeQuarters, .full])
        XCTAssertNil(BatteryLevel(canonValue: 3))
        XCTAssertEqual(BatteryLevel.threeQuarters.text, "75%")
        XCTAssertEqual(BatteryLevel.low.text, "Low")
    }

    func testEVFOutputDevice() {
        XCTAssertEqual(DirectLiveView.evfOutputDevice(showOnCameraScreen: true), 3)
        XCTAssertEqual(DirectLiveView.evfOutputDevice(showOnCameraScreen: false), 2)
    }
}
