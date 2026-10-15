import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 1024 * 3, bitsPerPixel: 24)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(red: 0.027, green: 0.055, blue: 0.071, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
NSColor(red: 0.08, green: 0.14, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 105, y: 105, width: 814, height: 814), xRadius: 90, yRadius: 90).fill()
let cyan = NSColor(red: 0.25, green: 0.90, blue: 0.91, alpha: 1)
let amber = NSColor(red: 1, green: 0.72, blue: 0.30, alpha: 1)
for (index, height) in [150.0, 210, 290, 240, 380, 315].enumerated() {
    (index < 3 ? cyan : amber).setFill()
    NSBezierPath(roundedRect: NSRect(x: 205 + Double(index) * 105, y: 225, width: 66, height: height), xRadius: 18, yRadius: 18).fill()
}
let label = NSAttributedString(string: "QWEN", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 132, weight: .semibold), .foregroundColor: NSColor.white])
label.draw(at: NSPoint(x: 512 - label.size().width / 2, y: 665))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("Icon.png"))
let contents = """
{"images":[{"filename":"Icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
