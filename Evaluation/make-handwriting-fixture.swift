// Renders handwriting-ocr-test.jpg, a synthetic handwritten-style notebook page
// for handwriting-ocr-expected.md: macOS's Bradley Hand font with per-word
// jitter on ruled paper, a slight page rotation, and stacked fractions. It is
// a license-free stand-in until real handwritten samples are collected. Also
// writes handwriting-ocr-test.lines.json with each written line's box, in the
// same format as vision-lines.swift.
//
//     swift Evaluation/make-handwriting-fixture.swift
import AppKit

indirect enum Piece {
    case text(String), sub(String), sup(String), frac([Piece], [Piece])
}

struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let width = 1500, height = 2000
let font = NSFont(name: "Bradley Hand Bold", size: 50) ?? NSFont(name: "Bradley Hand", size: 50)!
let small = NSFont(name: font.fontName, size: 34)!
let ink = NSColor(red: 0.08, green: 0.13, blue: 0.42, alpha: 1)
var random = Generator(state: 20260924)

// Hand-broken lines; nil starts a blank ruled line.
let lines: [[Piece]?] = [
    [.text("Physics review, Sept 24")],
    nil,
    [.text("Kinematics with constant acceleration:")],
    [.text("v = v"), .sub("0"), .text(" + at")],
    [.text("x = x"), .sub("0"), .text(" + v"), .sub("0"), .text("t + "), .frac([.text("1")], [.text("2")]),
     .text(" at"), .sup("2")],
    [.text("v"), .sup("2"), .text(" = v"), .sub("0"), .sup("2"), .text(" + 2a(x - x"), .sub("0"), .text(")")],
    nil,
    [.text("Example: a ball is thrown straight up at 12 m/s.")],
    [.text("How high does it go?")],
    [.text("At the top v = 0, so h = "), .frac([.text("v"), .sub("0"), .sup("2")], [.text("2g")]),
     .text(" = "), .frac([.text("144")], [.text("19.6")]), .text(" ≈ 7.3 m.")],
    [.text("Remember: the acceleration is -9.8 m/s"), .sup("2"), .text(" the whole")],
    [.text("time, even at the top.")],
    [.text("Energy check: "), .frac([.text("1")], [.text("2")]), .text(" m v"), .sub("0"), .sup("2"),
     .text(" = m g h, the mass cancels.")],
    nil,
    [.text("To do: problems 3, 7 and 12 from chapter 2.")]
]

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
cg.translateBy(x: 0, y: CGFloat(height))
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
// The sheet, slightly rotated as in a phone photo.
cg.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
cg.rotate(by: 0.012)
cg.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
NSColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1).setFill()
NSRect(x: 40, y: 40, width: width - 80, height: height - 80).fill()
let lineSpacing: CGFloat = 104, firstBaseline: CGFloat = 220
NSColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.8).setFill()
var ruled = firstBaseline
while ruled < CGFloat(height) - 60 { NSRect(x: 40, y: ruled + 8, width: CGFloat(width) - 80, height: 2).fill(); ruled += lineSpacing }
NSColor(red: 0.9, green: 0.45, blue: 0.45, alpha: 0.8).setFill()
NSRect(x: 170, y: 40, width: 3, height: CGFloat(height) - 80).fill()

/// Ink extent of the line being written, in unrotated page coordinates.
var lineBox = CGRect.null
var measuring = false

func draw(_ string: String, font: NSFont, x: inout CGFloat, baseline: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    for (index, word) in string.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
        if index > 0 { x += font.pointSize * 0.32 + CGFloat.random(in: -3...5, using: &random) }
        guard !word.isEmpty else { continue }
        let text = NSAttributedString(string: String(word), attributes: attributes)
        let jitter = CGFloat.random(in: -4...4, using: &random)
        NSGraphicsContext.saveGraphicsState()
        cg.translateBy(x: x, y: baseline + jitter)
        cg.rotate(by: CGFloat.random(in: -0.035...0.035, using: &random))
        text.draw(at: NSPoint(x: 0, y: -font.ascender))
        NSGraphicsContext.restoreGraphicsState()
        if !measuring {
            lineBox = lineBox.union(CGRect(x: x, y: baseline + jitter - font.ascender * 0.8,
                                           width: text.size().width, height: font.ascender * 0.8 - font.descender))
        }
        x += text.size().width
    }
}

func width(of pieces: [Piece]) -> CGFloat {
    var x: CGFloat = 0
    let saved = random
    measuring = true
    layout(pieces, x: &x, baseline: -10_000)
    measuring = false
    random = saved
    return x
}

func layout(_ pieces: [Piece], x: inout CGFloat, baseline: CGFloat) {
    var lastScriptX: CGFloat?
    for piece in pieces {
        switch piece {
        case .text(let string):
            lastScriptX = nil
            draw(string, font: font, x: &x, baseline: baseline)
        case .sub(let string):
            var start = x; lastScriptX = x
            draw(string, font: small, x: &start, baseline: baseline + 14); x = start
        case .sup(let string):
            // A superscript after a subscript stacks above it.
            var start = lastScriptX ?? x
            draw(string, font: small, x: &start, baseline: baseline - 26); x = max(x, start)
        case .frac(let numerator, let denominator):
            lastScriptX = nil
            let top = width(of: numerator), bottom = width(of: denominator)
            let span = max(top, bottom) + 16
            var nx = x + (span - top) / 2, dx = x + (span - bottom) / 2
            layout(numerator, x: &nx, baseline: baseline - 38)
            layout(denominator, x: &dx, baseline: baseline + 34)
            if !measuring {
                let rule = NSBezierPath()
                rule.lineWidth = 3.5
                rule.move(to: NSPoint(x: x, y: baseline - 14))
                rule.line(to: NSPoint(x: x + span, y: baseline - 12))
                ink.setStroke(); rule.stroke()
            }
            x += span + 6
        }
    }
}

struct Line: Encodable { let text: String; let box: [Double] }
var boxes: [Line] = []
func plain(_ pieces: [Piece]) -> String {
    pieces.map { piece in
        switch piece {
        case .text(let string): string
        case .sub(let string): "_" + string
        case .sup(let string): "^" + string
        case .frac(let numerator, let denominator): "(\(plain(numerator)))/(\(plain(denominator)))"
        }
    }.joined()
}
/// Maps an unrotated page point through the sheet rotation, normalized to 0...1.
func normalized(_ point: CGPoint) -> CGPoint {
    let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2), angle: CGFloat = 0.012
    let dx = point.x - center.x, dy = point.y - center.y
    return CGPoint(x: (center.x + dx * cos(angle) - dy * sin(angle)) / CGFloat(width),
                   y: (center.y + dx * sin(angle) + dy * cos(angle)) / CGFloat(height))
}

var baseline = firstBaseline
for (index, line) in lines.enumerated() {
    defer { baseline += lineSpacing }
    guard let line else { continue }
    var x: CGFloat = index == 0 ? 330 : 200 + CGFloat.random(in: -6...6, using: &random)
    let start = x
    lineBox = .null
    layout(line, x: &x, baseline: baseline)
    let corners = [CGPoint(x: lineBox.minX, y: lineBox.minY), CGPoint(x: lineBox.maxX, y: lineBox.minY),
                   CGPoint(x: lineBox.minX, y: lineBox.maxY), CGPoint(x: lineBox.maxX, y: lineBox.maxY)].map(normalized)
    boxes.append(Line(text: plain(line), box: [corners.map(\.x).min()!, corners.map(\.y).min()!,
        corners.map(\.x).max()!, corners.map(\.y).max()!].map { (Double($0) * 10_000).rounded() / 10_000 }))
    if index == 0 {
        let underline = NSBezierPath()
        underline.lineWidth = 3.5
        underline.move(to: NSPoint(x: start - 10, y: baseline + 18))
        underline.curve(to: NSPoint(x: x + 10, y: baseline + 12), controlPoint1: NSPoint(x: start + 200, y: baseline + 24),
                        controlPoint2: NSPoint(x: x - 200, y: baseline + 8))
        ink.setStroke(); underline.stroke()
    }
}

NSGraphicsContext.current = nil
let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
try jpeg.write(to: directory.appendingPathComponent("handwriting-ocr-test.jpg"))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted]
try encoder.encode(boxes).write(to: directory.appendingPathComponent("handwriting-ocr-test.lines.json"))
print("wrote handwriting-ocr-test.jpg and its line boxes")
