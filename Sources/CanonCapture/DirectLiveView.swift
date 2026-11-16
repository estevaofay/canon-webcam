import CLibUSB
import Foundation

/// Errors from the direct USB live-view path.
public struct PTPError: Error, CustomStringConvertible {
    public enum Kind {
        /// No Canon camera on USB.
        case noCamera
        /// The camera doesn't speak Canon EOS live view; use libgphoto2 instead.
        case unsupported
        /// USB failed: unplugged, switched off, or the camera stopped answering.
        case usb(Int32)
        /// The camera answered a command with an error code.
        case response(UInt16)
        /// The camera sent something that isn't valid PTP.
        case malformed

        public var isUnsupported: Bool {
            if case .unsupported = self { return true }
            return false
        }
    }

    public let kind: Kind
    public let action: String

    public var isDisconnect: Bool {
        switch kind {
        case .usb, .noCamera: return true
        default: return false
        }
    }

    public var description: String {
        switch kind {
        case .noCamera: return "\(action) failed: no Canon camera on USB"
        case .unsupported: return "\(action): this camera has no Canon EOS live view"
        case let .usb(code): return "\(action) failed: \(String(cString: libusb_error_name(code))) (\(code))"
        case let .response(code): return "\(action) failed: camera replied 0x\(String(code, radix: 16))"
        case .malformed: return "\(action) failed: unexpected reply from camera"
        }
    }
}

/// Canon EOS live view over USB, speaking PTP directly instead of through
/// libgphoto2.
///
/// libgphoto2 is careful and generic: before every live-view frame it re-reads
/// two live-view settings, sends a keep-awake, and polls for camera events, so
/// each frame costs about five USB round trips. On a Rebel T5 that caps live
/// view at about 14 fps. This class asks for the frame and nothing else (it
/// polls events and keeps the camera awake about once a second), which gets
/// about 21 fps from the same camera.
///
/// Not thread-safe: use one instance from one thread.
public final class DirectLiveView {
    // PTP operation codes.
    private enum Op {
        static let getDeviceInfo: UInt16 = 0x1001
        static let openSession: UInt16 = 0x1002
        static let closeSession: UInt16 = 0x1003
        static let setDevicePropValueEx: UInt16 = 0x9110  // Canon EOS
        static let setRemoteMode: UInt16 = 0x9114
        static let setEventMode: UInt16 = 0x9115
        static let getEvent: UInt16 = 0x9116
        static let keepDeviceOn: UInt16 = 0x911D
        static let terminateViewfinder: UInt16 = 0x9152
        static let getViewFinderData: UInt16 = 0x9153
    }

    private enum Response {
        static let ok: UInt16 = 0x2001
        static let deviceBusy: UInt16 = 0x2019
        static let sessionAlreadyOpen: UInt16 = 0x201E
        static let notReady: UInt16 = 0xA102  // Canon: no live-view frame yet
    }

    private enum Prop {
        static let evfOutputDevice: UInt32 = 0xD1B0  // bit mask: 1 = camera screen, 2 = PC
        static let evfMode: UInt32 = 0xD1B1          // 1 = live view enabled
        static let autoLightingOptimizer: UInt32 = 0xD1C1  // 0 standard, 1 low, 2 high, 3 off
    }

    private static let canonVendorID: UInt16 = 0x04A9
    private static let stillImageClass: UInt8 = 6
    private static let timeoutMs: UInt32 = 3000

    /// The camera's model name, e.g. "Canon EOS 1200D" (Rebel T5).
    public private(set) var model = ""

    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private var interfaceNumber: Int32 = 0
    private var endpointIn: UInt8 = 0
    private var endpointOut: UInt8 = 0
    private var transactionID: UInt32 = 0
    private var supportedOps = Set<UInt16>()
    private var buffer: UnsafeMutableRawPointer
    private var capacity: Int
    private var sessionOpen = false
    private var liveViewStarted = false
    private var lastHousekeeping = Date.distantPast
    private var lastKeepAwake = Date.distantPast
    private let turnOffAutoLightingOptimizer: Bool
    /// The camera's own ALO setting, to put back on close (nil: not changed).
    private var savedAutoLightingOptimizer: UInt32?

    /// Connects to the first Canon camera on USB and starts live view.
    /// Throws `.unsupported` for cameras that need libgphoto2 instead.
    ///
    /// With `turnOffAutoLightingOptimizer`, Auto Lighting Optimizer is switched
    /// off while streaming and restored on `close()`. ALO post-processes every
    /// live-view frame; on a Rebel T5 it makes the camera miss its 30 Hz frame
    /// slots, and turning it off takes live view from about 21 to about 28.5 fps.
    public init(turnOffAutoLightingOptimizer: Bool = true) throws {
        self.turnOffAutoLightingOptimizer = turnOffAutoLightingOptimizer
        capacity = 1 << 20
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        do {
            try connect()
            try startLiveView()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
        buffer.deallocate()
    }

    // MARK: Connecting

    private func connect() throws {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0 else { throw PTPError(kind: .usb(-1), action: "start libusb") }
        context = ctx

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count >= 0, let list else { throw PTPError(kind: .usb(Int32(count)), action: "list USB devices") }
        defer { libusb_free_device_list(list, 1) }

        var found: (device: OpaquePointer, interface: Int32, epIn: UInt8, epOut: UInt8)?
        for i in 0..<count {
            guard let device = list[i] else { continue }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0,
                  descriptor.idVendor == Self.canonVendorID else { continue }
            if let ptp = Self.ptpInterface(of: device) {
                found = (device, ptp.number, ptp.epIn, ptp.epOut)
                break
            }
        }
        guard let found else { throw PTPError(kind: .noCamera, action: "connect to camera") }
        interfaceNumber = found.interface
        endpointIn = found.epIn
        endpointOut = found.epOut

        var h: OpaquePointer?
        let opened = libusb_open(found.device, &h)
        guard opened == 0, let h else { throw PTPError(kind: .usb(opened), action: "open camera") }
        handle = h

        // macOS's ptpcamerad grabs the camera for Photos and respawns when
        // killed; claim the interface in the window after stopping it.
        var claimed: Int32 = -1
        for _ in 0..<5 {
            MacOSCameraDaemon.release()
            claimed = libusb_claim_interface(h, interfaceNumber)
            if claimed == 0 { break }
            usleep(200_000)
        }
        guard claimed == 0 else { throw PTPError(kind: .usb(claimed), action: "claim the USB device") }

        // A previous run that was killed mid-frame can leave the camera halfway
        // through a transfer, and it then ignores new commands. Throw away
        // anything still in flight; if the camera still doesn't answer, reset
        // its PTP state (a USB class request) and try once more.
        drainPendingInput(h)
        var opening: UInt16
        do {
            opening = try transaction(Op.openSession, [1])
        } catch let error as PTPError {
            guard case let .usb(code) = error.kind, code == LIBUSB_ERROR_TIMEOUT.rawValue else { throw error }
            resetPTPState(h)
            transactionID = 0
            opening = try transaction(Op.openSession, [1])
        }
        guard opening == Response.ok || opening == Response.sessionAlreadyOpen else {
            throw PTPError(kind: .response(opening), action: "open PTP session")
        }
        sessionOpen = true

        try expect(transaction(Op.getDeviceInfo), "read device info")
        try parseDeviceInfo()
        let needed = [Op.setDevicePropValueEx, Op.setRemoteMode, Op.setEventMode, Op.getEvent, Op.getViewFinderData]
        guard needed.allSatisfy(supportedOps.contains) else {
            throw PTPError(kind: .unsupported, action: model.isEmpty ? "connect" : model)
        }
    }

    /// Reads and discards whatever the camera is still sending from an
    /// interrupted transaction.
    private func drainPendingInput(_ handle: OpaquePointer) {
        for _ in 0..<64 {
            var received: Int32 = 0
            let result = libusb_bulk_transfer(
                handle, endpointIn, buffer.assumingMemoryBound(to: UInt8.self), Int32(capacity & ~511), &received, 100)
            if result != 0 || received == 0 { break }
        }
    }

    /// PTP-over-USB "Device Reset" (class request 0x66), then clears both bulk
    /// endpoints: brings a camera stuck in a half-finished transaction back.
    private func resetPTPState(_ handle: OpaquePointer) {
        _ = libusb_control_transfer(handle, 0x21, 0x66, 0, UInt16(interfaceNumber), nil, 0, 2000)
        _ = libusb_clear_halt(handle, endpointIn)
        _ = libusb_clear_halt(handle, endpointOut)
        usleep(300_000)
        drainPendingInput(handle)
    }

    /// Finds the camera's PTP (still image class) interface and its bulk endpoints.
    private static func ptpInterface(of device: OpaquePointer) -> (number: Int32, epIn: UInt8, epOut: UInt8)? {
        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(device, &config) == 0, let config else { return nil }
        defer { libusb_free_config_descriptor(config) }
        for i in 0..<Int(config.pointee.bNumInterfaces) {
            let interface = config.pointee.interface[i]
            for a in 0..<Int(interface.num_altsetting) {
                let setting = interface.altsetting[a]
                guard setting.bInterfaceClass == stillImageClass else { continue }
                var epIn: UInt8 = 0, epOut: UInt8 = 0
                for e in 0..<Int(setting.bNumEndpoints) {
                    let endpoint = setting.endpoint[e]
                    guard endpoint.bmAttributes & 3 == UInt8(LIBUSB_TRANSFER_TYPE_BULK.rawValue) else { continue }
                    if endpoint.bEndpointAddress & 0x80 != 0 { epIn = endpoint.bEndpointAddress }
                    else { epOut = endpoint.bEndpointAddress }
                }
                if epIn != 0 && epOut != 0 { return (Int32(setting.bInterfaceNumber), epIn, epOut) }
            }
        }
        return nil
    }

    private func startLiveView() throws {
        try expect(transaction(Op.setRemoteMode, [1]), "enable remote control")
        try expect(transaction(Op.setEventMode, [1]), "enable camera events")
        _ = try transaction(Op.getEvent)  // the camera reports all its settings once
        if turnOffAutoLightingOptimizer { try switchOffAutoLightingOptimizer(settings: currentSettings()) }

        // Live view on, sent to the PC. Right after connecting the camera can
        // answer "busy" for a moment.
        _ = try setProperty(Prop.evfMode, 1)
        var result = Response.deviceBusy
        for _ in 0..<20 {
            result = try setProperty(Prop.evfOutputDevice, 2)
            if result == Response.ok { break }
            _ = try transaction(Op.getEvent)
            usleep(100_000)
        }
        try expect(result, "start live view")
        liveViewStarted = true
        lastHousekeeping = Date()
    }

    // MARK: Frames

    /// Waits for and returns the next live-view frame (a JPEG, 1056x704 on a
    /// Rebel T3i/T5). The first frame takes about a second: the mirror has to
    /// go up.
    public func nextFrame() throws -> Data {
        housekeeping()
        let deadline = Date().addingTimeInterval(lastFrameAt == nil ? 6 : 3)
        while true {
            let result = try transaction(Op.getViewFinderData, [0x0010_0000, 0, 0])
            if result == Response.ok, let jpeg = jpegInPayload() {
                lastFrameAt = Date()
                return jpeg
            }
            if result != Response.ok && result != Response.notReady && result != Response.deviceBusy {
                throw PTPError(kind: .response(result), action: "read live-view frame")
            }
            // Not ready yet (the camera is metering, focusing, or simply
            // hasn't finished the next frame): ask again shortly.
            if Date() > deadline { throw PTPError(kind: .response(result), action: "wait for live-view frame") }
            usleep(500)
        }
    }

    private var lastFrameAt: Date?

    /// The payload is one or more blocks with an 8-byte header; the JPEG is in
    /// one of them. Rather than depend on header layouts that differ between
    /// models, find the JPEG markers.
    private func jpegInPayload() -> Data? {
        let length = lastDataLength
        guard length > 16 else { return nil }
        let bytes = buffer.advanced(by: 12).assumingMemoryBound(to: UInt8.self)
        var start = -1
        for i in 0..<min(64, length - 1) where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 {
            start = i
            break
        }
        guard start >= 0 else { return nil }
        var end = length
        var i = length - 2
        while i > start {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD9 { end = i + 2; break }
            i -= 1
        }
        return Data(bytes: bytes + start, count: end - start)
    }

    /// About once a second: drain the camera's event queue (it stalls if
    /// nobody reads it) and keep it from powering off.
    private func housekeeping() {
        let now = Date()
        guard now.timeIntervalSince(lastHousekeeping) >= 1 else { return }
        lastHousekeeping = now
        _ = try? transaction(Op.getEvent)
        if supportedOps.contains(Op.keepDeviceOn) && now.timeIntervalSince(lastKeepAwake) >= 30 {
            lastKeepAwake = now
            _ = try? transaction(Op.keepDeviceOn)
        }
    }

    // MARK: Auto Lighting Optimizer

    private static let autoLightingOptimizerOff: UInt32 = 3

    /// Where the camera's own ALO setting is kept while canon-webcam has it
    /// switched off, so it can still be restored if canon-webcam is killed
    /// before it gets the chance (the next run puts it back).
    private static var savedSettingFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/canon-webcam/auto-lighting-optimizer")
    }

    private func switchOffAutoLightingOptimizer(settings: [UInt32: UInt32]) throws {
        guard let current = settings[Prop.autoLightingOptimizer] else { return }  // not on this model
        // If a previous run was killed while ALO was off, the camera now reports
        // "off": the setting to restore is the one saved by that run.
        let saved = (try? String(contentsOf: Self.savedSettingFile, encoding: .utf8))
            .flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let original = (current == Self.autoLightingOptimizerOff ? saved : nil) ?? current
        guard original != Self.autoLightingOptimizerOff else {
            try? FileManager.default.removeItem(at: Self.savedSettingFile)
            return  // the user keeps ALO off anyway
        }
        try? FileManager.default.createDirectory(
            at: Self.savedSettingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(original)\n".write(to: Self.savedSettingFile, atomically: true, encoding: .utf8)
        savedAutoLightingOptimizer = original
        if current != Self.autoLightingOptimizerOff {
            try expect(setProperty(Prop.autoLightingOptimizer, Self.autoLightingOptimizerOff),
                       "turn off Auto Lighting Optimizer")
        }
    }

    private func restoreAutoLightingOptimizer() {
        guard let original = savedAutoLightingOptimizer else { return }
        if (try? setProperty(Prop.autoLightingOptimizer, original)) == Response.ok {
            savedAutoLightingOptimizer = nil
            try? FileManager.default.removeItem(at: Self.savedSettingFile)
        }
    }

    /// Reads property values from the GetEvent reply in `buffer`: a list of
    /// records (u32 size, u32 type, ...); type 0xC189 is "property value
    /// changed" (u32 property, then the value).
    private func currentSettings() -> [UInt32: UInt32] {
        var settings: [UInt32: UInt32] = [:]
        var offset = 12
        let end = 12 + lastDataLength
        while offset + 8 <= end {
            let size = Int(load32(offset))
            let type = load32(offset + 4)
            guard size >= 8, offset + size <= end else { break }
            if type == 0xC189 && size >= 16 {
                settings[load32(offset + 8)] = load32(offset + 12)
            }
            offset += size
        }
        return settings
    }

    // MARK: Closing

    /// Leaves live view (mirror down, camera screen back on) and releases the
    /// camera. Safe to call more than once.
    public func close() {
        if let handle {
            if sessionOpen {
                restoreAutoLightingOptimizer()
                if liveViewStarted && supportedOps.contains(Op.terminateViewfinder) {
                    _ = try? transaction(Op.terminateViewfinder)
                }
                _ = try? transaction(Op.getEvent)
                _ = try? transaction(Op.setRemoteMode, [0])
                _ = try? transaction(Op.setRemoteMode, [1])  // turns the camera's screen back on
                _ = try? transaction(Op.setEventMode, [0])
                _ = try? transaction(Op.closeSession)
                sessionOpen = false
                liveViewStarted = false
            }
            libusb_release_interface(handle, interfaceNumber)
            libusb_close(handle)
            self.handle = nil
        }
        if let context {
            libusb_exit(context)
            self.context = nil
        }
    }

    // MARK: PTP over USB

    private var lastDataLength = 0

    private func expect(_ result: UInt16, _ action: String) throws {
        if result != Response.ok { throw PTPError(kind: .response(result), action: action) }
    }

    private func setProperty(_ property: UInt32, _ value: UInt32) throws -> UInt16 {
        var data = [UInt8]()
        for word in [UInt32(12), property, value] { withUnsafeBytes(of: word.littleEndian) { data += $0 } }
        return try transaction(Op.setDevicePropValueEx, send: data)
    }

    /// Runs one PTP transaction and returns the camera's response code. Data
    /// the camera sends back is left in `buffer` at offset 12, `lastDataLength`
    /// bytes long.
    @discardableResult
    private func transaction(_ code: UInt16, _ params: [UInt32] = [], send data: [UInt8]? = nil) throws -> UInt16 {
        guard let handle else { throw PTPError(kind: .usb(Int32(LIBUSB_ERROR_NO_DEVICE.rawValue)), action: "talk to camera") }
        transactionID &+= 1
        let action = "PTP 0x\(String(code, radix: 16))"
        lastDataLength = 0

        try write(container(type: 1, code: code, payload: params.flatMap(Self.littleEndianBytes)), handle, action)
        if let data { try write(container(type: 2, code: code, payload: data), handle, action) }

        // Read containers until the response arrives. A data container comes
        // first if the operation returns data; with some cameras the response
        // follows in the same USB transfer.
        while true {
            var got = try read(into: 0, handle, action)
            if got == 0 { continue }  // zero-length packet ending a previous transfer
            guard got >= 12 else { throw PTPError(kind: .malformed, action: action) }
            let total = Int(load32(0))
            let type = load16(4)
            if type == 3 { return load16(6) }
            guard type == 2, total >= 12 else { throw PTPError(kind: .malformed, action: action) }

            while got < total {
                ensureCapacity(total + 512)
                let n = try read(into: got, handle, action)
                got += n
            }
            lastDataLength = total - 12
            if got >= total + 12 && load16(total + 4) == 3 { return load16(total + 6) }
            // Otherwise the response is the next container. Read it past the
            // data so the frame stays intact.
            ensureCapacity(total + 1024)
            while true {
                let n = try read(into: roundUp(total), handle, action)
                if n == 0 { continue }
                guard n >= 12, load16(roundUp(total) + 4) == 3 else { throw PTPError(kind: .malformed, action: action) }
                return load16(roundUp(total) + 6)
            }
        }
    }

    private func container(type: UInt16, code: UInt16, payload: [UInt8]) -> [UInt8] {
        var bytes = Self.littleEndianBytes(UInt32(12 + payload.count))
        bytes += Self.littleEndianBytes(type)
        bytes += Self.littleEndianBytes(code)
        bytes += Self.littleEndianBytes(transactionID)
        return bytes + payload
    }

    private func write(_ bytes: [UInt8], _ handle: OpaquePointer, _ action: String) throws {
        var bytes = bytes
        var sent: Int32 = 0
        let result = libusb_bulk_transfer(handle, endpointOut, &bytes, Int32(bytes.count), &sent, Self.timeoutMs)
        if result != 0 { throw PTPError(kind: .usb(result), action: action) }
    }

    /// Reads one USB transfer into `buffer` at `offset`. Requests whole
    /// 512-byte packets so the transfer can never overflow.
    private func read(into offset: Int, _ handle: OpaquePointer, _ action: String) throws -> Int {
        let room = (capacity - offset) & ~511
        guard room > 0 else { throw PTPError(kind: .malformed, action: action) }
        var received: Int32 = 0
        let result = libusb_bulk_transfer(
            handle, endpointIn, buffer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
            Int32(room), &received, Self.timeoutMs)
        if result != 0 { throw PTPError(kind: .usb(result), action: action) }
        return Int(received)
    }

    private func ensureCapacity(_ needed: Int) {
        let needed = roundUp(needed) + 512
        guard needed > capacity else { return }
        let bigger = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        bigger.copyMemory(from: buffer, byteCount: capacity)
        buffer.deallocate()
        buffer = bigger
        capacity = needed
    }

    private func roundUp(_ n: Int) -> Int { (n + 511) & ~511 }
    private func load16(_ offset: Int) -> UInt16 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    private func load32(_ offset: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    // MARK: Device info

    /// Reads the model name and the list of supported operations from a
    /// PTP DeviceInfo dataset.
    private func parseDeviceInfo() throws {
        let length = lastDataLength
        var offset = 12
        let end = 12 + length
        func u16() throws -> UInt16 {
            guard offset + 2 <= end else { throw PTPError(kind: .malformed, action: "read device info") }
            defer { offset += 2 }
            return load16(offset)
        }
        func u32() throws -> UInt32 {
            guard offset + 4 <= end else { throw PTPError(kind: .malformed, action: "read device info") }
            defer { offset += 4 }
            return load32(offset)
        }
        func string() throws -> String {
            guard offset + 1 <= end else { throw PTPError(kind: .malformed, action: "read device info") }
            let count = Int(buffer.load(fromByteOffset: offset, as: UInt8.self))
            offset += 1
            var units = [UInt16]()
            for _ in 0..<count { units.append(try u16()) }
            if units.last == 0 { units.removeLast() }
            return String(decoding: units, as: UTF16.self)
        }
        func u16Array() throws -> [UInt16] {
            let count = Int(try u32())
            guard count <= (end - offset) / 2 else { throw PTPError(kind: .malformed, action: "read device info") }
            return try (0..<count).map { _ in try u16() }
        }

        _ = try u16()       // standard version
        _ = try u32()       // vendor extension ID
        _ = try u16()       // vendor extension version
        _ = try string()    // vendor extension description
        _ = try u16()       // functional mode
        supportedOps = Set(try u16Array())
        _ = try u16Array()  // events
        _ = try u16Array()  // device properties
        _ = try u16Array()  // capture formats
        _ = try u16Array()  // image formats
        _ = try string()    // manufacturer
        model = try string()
    }
}
