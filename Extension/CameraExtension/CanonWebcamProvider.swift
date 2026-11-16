import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import os.log

// The "Canon Webcam" virtual camera.
//
// It has two streams:
//  - a *sink* stream that the `canon-webcam` command-line tool writes the
//    DSLR's live-view frames into, and
//  - a *source* stream that video apps (Zoom, Meet, FaceTime, ...) read.
// Frames are forwarded unchanged from sink to source. When nothing is feeding
// the sink, apps see a placeholder frame explaining how to start the feed.

let deviceName = "Canon Webcam"
let deviceUUID = UUID(uuidString: "57313526-5EDB-4B40-803A-93504A08A3FB")!
let sourceStreamUUID = UUID(uuidString: "D2DBF573-EADB-45AA-8D47-BB8594620B13")!
let sinkStreamUUID = UUID(uuidString: "D54647FB-0D2F-4281-89C9-09E32B776F03")!

let frameWidth: Int32 = 1920
let frameHeight: Int32 = 1080
let framesPerSecond: Int32 = 30

private let logger = Logger(subsystem: "io.github.estevaofay.CanonWebcam", category: "extension")

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "canon-webcam (open source)" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: StreamSource!
    private var sinkStream: SinkStream!

    private let format: CMVideoFormatDescription
    private let queue = DispatchQueue(label: "canon-webcam.extension", qos: .userInteractive)
    private var placeholder: CMSampleBuffer?

    // All state below is only touched on `queue`.
    private var viewers = 0
    private var placeholderTimer: DispatchSourceTimer?
    private var consumeTimer: DispatchSourceTimer?
    private var sinkClient: CMIOExtensionClient?
    private var lastLiveFrame = Date.distantPast

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: frameWidth, height: frameHeight, extensions: nil, formatDescriptionOut: &description)
        format = description!
        super.init()

        device = CMIOExtensionDevice(
            localizedName: deviceName, deviceID: deviceUUID, legacyDeviceID: nil, source: self)

        let frameDuration = CMTime(value: 1, timescale: framesPerSecond)
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format, maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration, validFrameDurations: nil)
        sourceStream = StreamSource(streamID: sourceStreamUUID, format: streamFormat, device: self)
        sinkStream = SinkStream(streamID: sinkStreamUUID, format: streamFormat, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
        placeholder = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = deviceName }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source (apps watching the camera)

    func startViewing() {
        queue.async { [self] in
            viewers += 1
            guard placeholderTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(framesPerSecond))
            timer.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            timer.resume()
            placeholderTimer = timer
        }
    }

    func stopViewing() {
        queue.async { [self] in
            viewers = max(0, viewers - 1)
            if viewers == 0 {
                placeholderTimer?.cancel()
                placeholderTimer = nil
            }
        }
    }

    private func sendPlaceholderIfIdle() {
        // Live frames are flowing: the camera feed wins.
        guard Date().timeIntervalSince(lastLiveFrame) > 1, let placeholder else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        sourceStream.stream.send(
            placeholder, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
    }

    // MARK: Sink (canon-webcam feeding frames)

    func startFeeding(from client: CMIOExtensionClient) {
        queue.async { [self] in
            sinkClient = client
            consumeTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // Poll faster than the DSLR delivers (~15-20 fps) so frames don't wait.
            timer.schedule(deadline: .now(), repeating: 1.0 / 60)
            timer.setEventHandler { [weak self] in self?.consumeFrame() }
            timer.resume()
            consumeTimer = timer
            logger.info("feed started")
        }
    }

    func stopFeeding() {
        queue.async { [self] in
            consumeTimer?.cancel()
            consumeTimer = nil
            sinkClient = nil
            lastLiveFrame = .distantPast
            logger.info("feed stopped")
        }
    }

    private func consumeFrame() {
        guard let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, _ in
            guard let self, let sample else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let hostTime = UInt64(now.seconds * Double(NSEC_PER_SEC))
            self.queue.async {
                self.lastLiveFrame = Date()
                if self.viewers > 0 {
                    self.sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
                }
            }
            self.sinkStream.stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: hostTime))
        }
    }

    // MARK: Placeholder frame

    private func makePlaceholder() -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(frameWidth), Int(frameHeight),
                                  kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer
        else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(frameWidth), height: Int(frameHeight), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        {
            context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: Int(frameWidth), height: Int(frameHeight)))
            drawCentered("Canon Webcam", size: 72, y: 600, in: context)
            drawCentered("Waiting for the camera. In Terminal, run:", size: 36, y: 480, in: context)
            drawCentered("canon-webcam --camera \"Canon Webcam\"", size: 36, y: 420, in: context, mono: true)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: framesPerSecond),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    private func drawCentered(_ text: String, size: CGFloat, y: CGFloat, in context: CGContext, mono: Bool = false) {
        let font = CTFontCreateWithName((mono ? "Menlo" : "Helvetica Neue") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (CGFloat(frameWidth) - width) / 2, y: y)
        CTLineDraw(line, context)
    }
}

// MARK: - Streams

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource
    private let format: CMIOExtensionStreamFormat

    init(streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.device = device
        self.format = format
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "\(deviceName) Video", streamID: streamID, direction: .source,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: framesPerSecond) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.startViewing() }
    func stopStream() throws { device.stopViewing() }
}

final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource
    private let format: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.device = device
        self.format = format
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "\(deviceName) Input", streamID: streamID, direction: .sink,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: framesPerSecond) }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        if let client { device.startFeeding(from: client) }
    }

    func stopStream() throws { device.stopFeeding() }
}
