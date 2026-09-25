// Renders screenshot-ocr-test.png, a 1320×2868 (iPhone Pro Max, 3×) notes-app
// screenshot of screenshot-ocr-expected.md. Chrome is drawn as shapes only, so
// every visible word is in the reference.
//
//     swift Evaluation/make-screenshot-fixture.swift
import AppKit

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let markdown = try String(contentsOf: directory.appendingPathComponent("screenshot-ocr-expected.md"), encoding: .utf8)
let width = 1320, height = 2868, scale: CGFloat = 3
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
// Top-left origin, like UIKit.
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
let accent = NSColor(red: 0.89, green: 0.64, blue: 0.0, alpha: 1)

// Status bar: signal bars, battery; navigation bar: back chevron, share and more buttons.
NSColor.black.setFill()
for index in 0..<4 {
    let barHeight = CGFloat(12 + index * 7) * 1.4
    NSBezierPath(roundedRect: NSRect(x: 1000 + CGFloat(index) * 22, y: 120 - barHeight, width: 15, height: barHeight),
                 xRadius: 3, yRadius: 3).fill()
}
NSBezierPath(roundedRect: NSRect(x: 1130, y: 78, width: 90, height: 44), xRadius: 12, yRadius: 12).fill()
accent.setStroke()
let chevron = NSBezierPath()
chevron.lineWidth = 9; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: 90, y: 215)); chevron.line(to: NSPoint(x: 60, y: 250)); chevron.line(to: NSPoint(x: 90, y: 285))
chevron.stroke()
for x in [1080.0, 1200.0] {
    let circle = NSBezierPath(ovalIn: NSRect(x: x, y: 215, width: 70, height: 70))
    circle.lineWidth = 7; circle.stroke()
}

// Body text from the Markdown reference.
let margin = 20 * scale
let body = NSFont.systemFont(ofSize: 17 * scale)
let paragraph = NSMutableParagraphStyle()
paragraph.lineSpacing = 4 * scale
paragraph.paragraphSpacing = 10 * scale
let bullet = paragraph.mutableCopy() as! NSMutableParagraphStyle
bullet.headIndent = 22 * scale
bullet.firstLineHeadIndent = 4 * scale
bullet.tabStops = [NSTextTab(textAlignment: .left, location: 22 * scale)]
bullet.paragraphSpacing = 6 * scale
let text = NSMutableAttributedString()
for line in markdown.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
    let (content, attributes): (String, [NSAttributedString.Key: Any])
    if line.hasPrefix("# ") {
        content = String(line.dropFirst(2))
        attributes = [.font: NSFont.systemFont(ofSize: 28 * scale, weight: .bold), .paragraphStyle: paragraph]
    } else if line.hasPrefix("## ") {
        content = String(line.dropFirst(3))
        let heading = paragraph.mutableCopy() as! NSMutableParagraphStyle
        heading.paragraphSpacingBefore = 8 * scale
        attributes = [.font: NSFont.systemFont(ofSize: 21 * scale, weight: .semibold), .paragraphStyle: heading]
    } else if line.hasPrefix("- ") {
        content = "•\t" + line.dropFirst(2)
        attributes = [.font: body, .paragraphStyle: bullet]
    } else if line.hasPrefix("Updated ") {
        content = line
        attributes = [.font: NSFont.systemFont(ofSize: 13 * scale), .foregroundColor: NSColor.gray, .paragraphStyle: paragraph]
    } else {
        content = line
        attributes = [.font: body, .paragraphStyle: paragraph]
    }
    var merged = attributes
    if merged[.foregroundColor] == nil { merged[.foregroundColor] = NSColor.black }
    text.append(NSAttributedString(string: content + "\n", attributes: merged))
}
text.draw(with: NSRect(x: margin, y: 330, width: CGFloat(width) - 2 * margin, height: 2300),
          options: [.usesLineFragmentOrigin, .usesFontLeading])

// Bottom toolbar icons and the home indicator.
accent.setStroke()
for x in [90.0, 380.0, 670.0, 960.0, 1180.0] {
    let icon = NSBezierPath(roundedRect: NSRect(x: x, y: 2690, width: 60, height: 60), xRadius: 12, yRadius: 12)
    icon.lineWidth = 7; icon.stroke()
}
NSColor.black.setFill()
NSBezierPath(roundedRect: NSRect(x: 440, y: 2825, width: 440, height: 15), xRadius: 7.5, yRadius: 7.5).fill()

NSGraphicsContext.current = nil
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("screenshot-ocr-test.png"))
print("wrote screenshot-ocr-test.png")
