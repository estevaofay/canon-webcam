import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOSurface

/// A CoreMediaIO camera (usually a Camera Extension) as seen by any app.
public struct CMIOCamera {
    public let id: CMIOObjectID
    public let name: String
    public let uid: String
    /// The stream other apps write frames into, if the camera has one.
    public let sinkStream: CMIOStreamID?

    public var acceptsFrames: Bool { sinkStream != nil }
}

public enum VirtualCameraError: Error, CustomStringConvertible {
    case notFound(name: String, available: [String])
    case noSink(name: String)
    case cmio(String, OSStatus)

    public var description: String {
        switch self {
        case let .notFound(name, available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "virtual camera \"\(name)\" not found (cameras that accept frames: \(list)). "
                + "Is its camera extension installed and allowed in System Settings > General > "
                + "Login Items & Extensions > Camera Extensions?"
        case let .noSink(name):
            return "\"\(name)\" is a camera but does not accept frames from other apps"
        case let .cmio(what, status):
            return "\(what) failed (OSStatus \(status))"
        }
    }
}

enum CMIOProperty {
    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func ids(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }
}

public enum VirtualCameras {
    /// Every camera CoreMediaIO knows about (real and virtual).
    public static func all() -> [CMIOCamera] {
        // Camera extensions are published asynchronously; give them a moment
        // on first use.
        var devices: [CMIOObjectID] = []
        for _ in 0..<20 {
            devices = CMIOProperty.ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            if !devices.isEmpty { break }
            usleep(100_000)
        }
        return devices.map { device in
            let streams = CMIOProperty.ids(device, kCMIODevicePropertyStreams)
            // Direction 0 = output stream from the client's point of view, i.e. a sink.
            let sink = streams.first { CMIOProperty.uint32($0, kCMIOStreamPropertyDirection) == 0 }
            return CMIOCamera(
                id: device,
                name: CMIOProperty.string(device, kCMIOObjectPropertyName) ?? "?",
                uid: CMIOProperty.string(device, kCMIODevicePropertyDeviceUID) ?? "?",
                sinkStream: sink)
        }
    }

    public static func named(_ name: String) throws -> CMIOCamera {
        let cameras = all()
        guard let camera = cameras.first(where: { $0.name == name }) else {
            throw VirtualCameraError.notFound(name: name, available: cameras.filter(\.acceptsFrames).map(\.name))
        }
        guard camera.acceptsFrames else { throw VirtualCameraError.noSink(name: name) }
        return camera
    }
}

/// Pushes frames into a virtual camera's sink stream. The camera extension
/// forwards them to whatever app (Zoom, Meet, FaceTime, ...) is using it.
public final class VirtualCameraSink {
    public let camera: CMIOCamera
    public private(set) var sent = 0
    public private(set) var dropped = 0
    /// IOSurface IDs of buffers sent, so `check` can recognise its own frames
    /// when they come back out of the virtual camera.
    public private(set) var sentSurfaceIDs = Set<IOSurfaceID>()
    /// Frames waiting in the queue / queue capacity, for diagnostics.
    public var queueDepth: (count: Int32, capacity: Int32) {
        (CMSimpleQueueGetCount(queue), CMSimpleQueueGetCapacity(queue))
    }

    private let stream: CMIOStreamID
    private let queue: CMSimpleQueue
    private var format: CMVideoFormatDescription?
    private var started = false

    public init(cameraNamed name: String) throws {
        camera = try VirtualCameras.named(name)
        stream = camera.sinkStream!

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanagedQueue)
        guard status == noErr, let unmanagedQueue else {
            throw VirtualCameraError.cmio("open the input of \"\(name)\"", status)
        }
        queue = unmanagedQueue.takeRetainedValue()

        let start = CMIODeviceStartStream(camera.id, stream)
        guard start == noErr else { throw VirtualCameraError.cmio("start \"\(name)\"", start) }
        started = true
    }

    deinit { stop() }

    public func stop() {
        guard started else { return }
        CMIODeviceStopStream(camera.id, stream)
        started = false
    }

    public func send(_ pixelBuffer: CVPixelBuffer) {
        // If the extension hasn't consumed the previous frame, drop this one
        // rather than adding latency.
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) {
            dropped += 1
            return
        }
        if format == nil
            || CMVideoFormatDescriptionGetDimensions(format!).width != Int32(CVPixelBufferGetWidth(pixelBuffer)) {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            format = description
        }
        guard let format else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { dropped += 1; return }

        // The queue takes ownership of one retain; the extension releases it.
        if CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque()) == noErr {
            sent += 1
            if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
                sentSurfaceIDs.insert(IOSurfaceGetID(surface))
            }
        } else {
            Unmanaged.passUnretained(sample).release()
            dropped += 1
        }
    }
}

/// Reads what a virtual camera outputs, the same way a video app would.
/// Used by `canon-webcam check` to confirm frames make it all the way through.
public final class VirtualCameraReader {
    public let camera: CMIOCamera
    private let stream: CMIOStreamID
    private let queue: CMSimpleQueue
    private var started = false

    public init(cameraNamed name: String) throws {
        camera = try VirtualCameras.named(name)
        let streams = CMIOProperty.ids(camera.id, kCMIODevicePropertyStreams)
        guard let source = streams.first(where: { CMIOProperty.uint32($0, kCMIOStreamPropertyDirection) == 1 })
        else { throw VirtualCameraError.noSink(name: name) }
        stream = source

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanagedQueue)
        guard status == noErr, let unmanagedQueue else {
            throw VirtualCameraError.cmio("open the output of \"\(name)\"", status)
        }
        queue = unmanagedQueue.takeRetainedValue()
        let start = CMIODeviceStartStream(camera.id, stream)
        guard start == noErr else { throw VirtualCameraError.cmio("start reading \"\(name)\"", start) }
        started = true
    }

    deinit { stop() }

    public func stop() {
        guard started else { return }
        CMIODeviceStopStream(camera.id, stream)
        started = false
    }

    /// Takes every frame received since the last call.
    public func drainFrames() -> [CVPixelBuffer] {
        var result: [CVPixelBuffer] = []
        while let element = CMSimpleQueueDequeue(queue) {
            let sample = Unmanaged<CMSampleBuffer>.fromOpaque(element).takeRetainedValue()
            if let image = CMSampleBufferGetImageBuffer(sample) { result.append(image) }
        }
        return result
    }

    /// Takes every frame received since the last call; returns each frame's
    /// IOSurface ID (0 if it has none).
    public func drain() -> [IOSurfaceID] {
        drainFrames().map { frame in
            CVPixelBufferGetIOSurface(frame).map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
        }
    }
}
