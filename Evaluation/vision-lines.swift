// Writes <image>.lines.json next to each image: Apple Vision's text lines as
// {text, box: [x1, y1, x2, y2]} normalized to 0...1 with a top-left origin.
// These are the reference boxes for the benchmark's bbox metrics on typeset
// pages; make-handwriting-fixture.swift writes exact boxes for its page.
//
//     swiftc -O Evaluation/vision-lines.swift -o /tmp/vision-lines
//     /tmp/vision-lines Evaluation/screenshot-ocr-test.png
//
// The fast recognizer is used because the accurate one fails with an e5rt
// error outside a GUI login session (seen over SSH on the Mac mini). Its line
// boxes are reliable on clean typeset text; its text is not used as a reference.
import Foundation
import Vision

struct Line: Encodable { let text: String; let box: [Double] }

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(url: url).perform([request])
    let lines = (request.results ?? []).compactMap { observation -> Line? in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        let box = observation.boundingBox
        return Line(text: text, box: [box.minX, 1 - box.maxY, box.maxX, 1 - box.minY].map { (Double($0) * 10_000).rounded() / 10_000 })
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let output = url.deletingPathExtension().appendingPathExtension("lines.json")
    try encoder.encode(lines).write(to: output)
    print("\(output.lastPathComponent): \(lines.count) lines")
}
