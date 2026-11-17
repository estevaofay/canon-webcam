import AppKit
import SwiftUI

/// The menu bar icon: a camera, with a small red dot while live.
struct MenuBarIcon: View {
    let live: Bool

    var body: some View {
        Image(nsImage: Self.image(live: live))
    }

    /// Idle: a template image, so macOS tints it for light and dark menu bars.
    /// Live: drawn at display time in the menu bar's own label colour, plus the
    /// red dot (a template image can't carry a colour).
    static func image(live: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: "camera", accessibilityDescription: "canon-webcam")!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        guard live else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: symbol.size.width + 3, height: max(symbol.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(at: NSPoint(x: 0, y: (rect.height - tinted.size.height) / 2), from: .zero,
                        operation: .sourceOver, fraction: 1)
            let dot = NSRect(x: rect.width - 7, y: rect.height - 7, width: 6, height: 6)
            NSColor(red: 0xE5 / 255, green: 0x32 / 255, blue: 0x2D / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "canon-webcam, live"
        return image
    }
}
