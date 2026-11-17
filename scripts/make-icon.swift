// Draws canon-webcam's 1024×1024 app icon: a white camera on a dark rounded
// square, with the red "live" dot from the menu bar icon.
// Usage: swift scripts/make-icon.swift OUTPUT.png
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824-point rounded square centred in the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(white: 0.24, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!
    .draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular)
    .applying(.init(paletteColors: [.white]))
let camera = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let cameraRect = NSRect(x: (CGFloat(size) - camera.size.width) / 2, y: (CGFloat(size) - camera.size.height) / 2 - 10,
                        width: camera.size.width, height: camera.size.height)
camera.draw(in: cameraRect)

let dot = NSRect(x: cameraRect.maxX - 70, y: cameraRect.maxY - 40, width: 120, height: 120)
NSColor(white: 0.08, alpha: 1).setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: -18, dy: -18)).fill()
NSColor(red: 0xE5 / 255, green: 0x32 / 255, blue: 0x2D / 255, alpha: 1).setFill()
NSBezierPath(ovalIn: dot).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
