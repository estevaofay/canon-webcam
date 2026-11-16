import CoreImage
import CoreVideo
import Foundation

/// Turns live-view JPEGs (3:2, e.g. 1056x704) into the 16:9 BGRA frames that
/// virtual cameras expect (1920x1080 by default).
public final class FrameRenderer {
    public enum Mode: String, CaseIterable {
        /// Crop the top and bottom to fill 16:9 (no black bars).
        case fill
        /// Show the whole 3:2 frame with black bars on the sides.
        case fit
    }

    public let width: Int
    public let height: Int
    public var mode: Mode

    private var pool: CVPixelBufferPool?
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let background: CIImage

    public init(width: Int = 1920, height: Int = 1080, mode: Mode = .fill) {
        self.width = width
        self.height = height
        self.mode = mode
        context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: colorSpace])
        background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    public func render(jpeg: Data) -> CVPixelBuffer? {
        guard let pool, let image = CIImage(data: jpeg) else { return nil }
        let source = image.extent
        let sx = CGFloat(width) / source.width
        let sy = CGFloat(height) / source.height
        let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - source.width * scale) / 2,
                y: (CGFloat(height) - source.height * scale) / 2))
            .composited(over: background)

        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, attrs, &buffer)
            == kCVReturnSuccess, let buffer else { return nil }
        context.render(placed, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: colorSpace)
        return buffer
    }
}
