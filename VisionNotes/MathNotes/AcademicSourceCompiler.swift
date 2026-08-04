import Foundation

enum AcademicSourceCompiler {
    static func standaloneHTML(markdown: String, title: String, assetRoot: URL) throws -> String {
        let body = try MarkdownHTMLRenderer(assetRoot: assetRoot).render(markdown)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <meta name="generator" content="Vision Notes on-device HTML + MathML renderer">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
          <title>\(escapeHTML(title))</title>
          <style>
            @page { size: A4; margin: 18mm 17mm 20mm; }
            :root { color-scheme: light dark; --ink:#172033; --muted:#667085; --rule:#d7dce5; --warn:#fff1c2; }
            * { box-sizing:border-box; }
            html { background:#fff; }
            body { margin:0 auto; max-width:920px; padding:36px 42px 64px; color:var(--ink); background:#fff;
                   font:17px/1.62 -apple-system,BlinkMacSystemFont,"New York","Noto Serif CJK SC",serif; }
            h1,h2,h3,h4 { line-height:1.25; margin:1.25em 0 .5em; break-after:avoid; }
            h1 { font-size:2rem; border-bottom:1px solid var(--rule); padding-bottom:.32em; }
            h2 { font-size:1.45rem; } h3 { font-size:1.18rem; }
            p { margin:.72em 0; orphans:3; widows:3; }
            ul,ol { padding-left:1.6em; } li { margin:.28em 0; }
            table { width:100%; border-collapse:collapse; margin:1em 0; break-inside:avoid; }
            th,td { border:1px solid var(--rule); padding:.42em .55em; vertical-align:top; }
            img { display:block; max-width:100%; max-height:245mm; object-fit:contain; margin:1em auto .35em; break-inside:avoid; }
            figure { margin:1.2em 0; break-inside:avoid; } figcaption { text-align:center; color:var(--muted); font-size:.88em; }
            math { font-size:1.06em; max-width:100%; }
            .display-math { display:block; overflow-x:auto; margin:.9em 0; padding:.12em 0; break-inside:avoid; text-align:center; }
            .unclear { background:var(--warn); color:#6b4f00; border-radius:4px; padding:0 .18em; }
            .toc { border:1px solid var(--rule); border-radius:10px; padding:1em 1.2em; margin:1.2em 0 2em; break-inside:avoid; }
            .toc h2 { margin:0 0 .5em; font-size:1.12rem; } .toc ol { margin:0; }
            .toc .level-2 { margin-left:1em; } .toc .level-3,.toc .level-4 { margin-left:2em; }
            .toc a { color:inherit; text-decoration:none; border-bottom:1px dotted var(--muted); }
            .page-break { break-before:page; page-break-before:always; height:0; }
            .renderer-note { color:var(--muted); font:12px/1.4 -apple-system,sans-serif; margin-bottom:2em; }
            @media print {
              :root { color-scheme:light; } html,body { background:#fff; color:#111; }
              body { max-width:none; padding:0; font-size:11pt; }
              .renderer-note { font-size:8pt; }
              .display-math { overflow:visible; }
            }
            @media (prefers-color-scheme:dark) and (screen) {
              :root { --ink:#e7eaf0; --muted:#aab2c0; --rule:#3b4351; --warn:#5a4610; }
              html,body { background:#151922; }
            }
          </style>
        </head>
        <body data-math-ready="true">
          <div class="renderer-note">Rendered locally by Vision Notes using HTML + MathML. Editable LaTeX source is included separately.</div>
          \(body)
        </body>
        </html>
        """
    }

    static func standaloneLaTeX(markdown: String, title: String) -> String {
        let body = MarkdownLaTeXRenderer().render(markdown)
        return """
        % Vision Notes Academic export
        % Human-readable XeLaTeX-compatible source. The bundled PDF was rendered locally
        % from the same Markdown through HTML + MathML, not by XeLaTeX.
        \\documentclass[11pt,a4paper]{article}
        \\usepackage[margin=18mm]{geometry}
        \\usepackage{fontspec}
        \\usepackage{xeCJK}
        \\usepackage{amsmath,amssymb,mathtools}
        \\usepackage{graphicx}
        \\usepackage{booktabs,longtable,array}
        \\usepackage{xcolor}
        \\usepackage[unicode,colorlinks=true,linkcolor=blue,urlcolor=blue]{hyperref}
        \\usepackage{bookmark}
        \\setmainfont{New York}
        \\setCJKmainfont{PingFang SC}
        \\graphicspath{{assets/}}
        \\title{\(escapeTeX(title))}
        \\author{Vision Notes Academic}
        \\date{}
        \\begin{document}
        \\maketitle
        \\tableofcontents
        \\clearpage

        \(body)

        \\end{document}
        """
    }

    static func facsimileHTML(title: String, pageData: [Data]) -> String {
        let pages = pageData.enumerated().map { index, data in
            "<figure><img alt=\"Source page \(index + 1)\" src=\"data:image/jpeg;base64,\(data.base64EncodedString())\"><figcaption>Page \(index + 1)</figcaption></figure>"
        }.joined(separator: "<div class=\"page-break\"></div>")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>\(escapeHTML(title)) — Facsimile</title><style>
        @page{size:A4;margin:0}*{box-sizing:border-box}html,body{margin:0;background:#111}figure{margin:0;min-height:100vh;display:grid;place-items:center;break-after:page;background:#fff}img{max-width:100%;max-height:100vh;object-fit:contain}.page-break{break-before:page}figcaption{position:absolute;left:-9999px}@media print{figure{width:210mm;height:297mm;min-height:0}img{max-width:210mm;max-height:297mm}}
        </style></head><body>\(pages)</body></html>
        """
    }

    static func facsimileLaTeX(title: String, pageCount: Int) -> String {
        let pages = (1...pageCount).map { index in
            let name = String(format: "pages/page-%03d.jpg", index)
            return "\\noindent\\includegraphics[width=\\paperwidth,height=\\paperheight,keepaspectratio]{\(name)}\\newpage"
        }.joined(separator: "\n")
        return """
        % Vision Notes facsimile source
        \\documentclass{article}
        \\usepackage[paper=a4paper,margin=0pt]{geometry}
        \\usepackage{graphicx}
        \\pagestyle{empty}
        \\begin{document}
        \(pages)
        \\end{document}
        """
    }

    fileprivate static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    fileprivate static func escapeTeX(_ value: String) -> String {
        value.map { character -> String in
            switch character {
            case "\\": "\\textbackslash{}"
            case "&": "\\&"
            case "%": "\\%"
            case "$": "\\$"
            case "#": "\\#"
            case "_": "\\_"
            case "{": "\\{"
            case "}": "\\}"
            case "~": "\\textasciitilde{}"
            case "^": "\\textasciicircum{}"
            default: String(character)
            }
        }.joined()
    }
}

private struct MarkdownHTMLRenderer {
    let assetRoot: URL

    func render(_ markdown: String) throws -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        var list: String?
        var index = 0
        var headingIndex = 0
        let headings = lines.compactMap(headingParts)

        func closeList(_ output: inout [String], _ list: inout String?) {
            if let list { output.append("</\(list)>") }
            list = nil
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "<div class=\"page-break\"></div>" || trimmed == "<!-- page-break -->" {
                closeList(&output, &list)
                output.append("<div class=\"page-break\" aria-hidden=\"true\"></div>")
                index += 1
                continue
            }
            if let block = multilineSingleDollarBlock(in: lines, startingAt: index) {
                closeList(&output, &list)
                output.append("<div class=\"display-math\">\(LaTeXMathMLConverter.render(block.math, display: true))</div>")
                index = block.nextIndex
                continue
            }
            if trimmed.hasPrefix("$$") {
                closeList(&output, &list)
                var math = String(trimmed.dropFirst(2))
                if math.hasSuffix("$$") {
                    math = String(math.dropLast(2))
                } else {
                    index += 1
                    while index < lines.count, !lines[index].contains("$$") {
                        math += "\n" + lines[index]
                        index += 1
                    }
                    if index < lines.count {
                        math += "\n" + lines[index].replacingOccurrences(of: "$$", with: "")
                    }
                }
                output.append("<div class=\"display-math\">\(LaTeXMathMLConverter.render(math, display: true))</div>")
                index += 1
                continue
            }
            if trimmed.isEmpty {
                closeList(&output, &list)
                index += 1
                continue
            }
            if let heading = headingParts(trimmed) {
                closeList(&output, &list)
                headingIndex += 1
                output.append("<h\(heading.level) id=\"section-\(headingIndex)\">\(try inline(heading.text))</h\(heading.level)>")
                index += 1
                continue
            }
            if let item = listItem(trimmed) {
                if list != item.kind {
                    closeList(&output, &list)
                    list = item.kind
                    output.append("<\(item.kind)>")
                }
                output.append("<li>\(try inline(item.text))</li>")
                index += 1
                continue
            }
            closeList(&output, &list)
            output.append("<p>\(try inline(trimmed))</p>")
            index += 1
        }
        closeList(&output, &list)
        let contents = headings.enumerated().map { offset, heading in
            "<li class=\"level-\(heading.level)\"><a href=\"#section-\(offset + 1)\">\(AcademicSourceCompiler.escapeHTML(heading.text))</a></li>"
        }.joined()
        let tableOfContents = headings.isEmpty
            ? ""
            : "<nav class=\"toc\" aria-label=\"Table of contents\"><h2>Contents</h2><ol>\(contents)</ol></nav>"
        return tableOfContents + "\n" + output.joined(separator: "\n")
    }

    private func multilineSingleDollarBlock(
        in lines: [String],
        startingAt startIndex: Int
    ) -> (math: String, nextIndex: Int)? {
        let opening = lines[startIndex].trimmingCharacters(in: .whitespaces)
        guard opening.hasPrefix("$"), !opening.hasPrefix("$$") else { return nil }
        let firstLine = String(opening.dropFirst())
        guard !firstLine.contains("$") else { return nil }

        var chunks = [firstLine]
        var index = startIndex + 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("$") {
                chunks.append(String(line.dropLast()))
                return (chunks.joined(separator: "\n"), index + 1)
            }
            chunks.append(line)
            index += 1
        }
        return nil
    }

    private func headingParts(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private func listItem(_ line: String) -> (kind: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return ("ul", String(line.dropFirst(2))) }
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return ("ol", String(line[range.upperBound...]))
        }
        return nil
    }

    private func inline(_ source: String) throws -> String {
        var output = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let tail = source[cursor...]
            if tail.hasPrefix("!["),
               let closeAlt = tail.firstIndex(of: "]"),
               source.index(after: closeAlt) < source.endIndex,
               source[source.index(after: closeAlt)] == "(",
               let closePath = source[source.index(closeAlt, offsetBy: 2)...].firstIndex(of: ")") {
                let alt = String(source[source.index(cursor, offsetBy: 2)..<closeAlt])
                let pathStart = source.index(closeAlt, offsetBy: 2)
                let path = String(source[pathStart..<closePath])
                output += try embeddedImage(path: path, alt: alt)
                cursor = source.index(after: closePath)
                continue
            }
            if tail.hasPrefix("**"),
               let close = source[source.index(cursor, offsetBy: 2)...].range(of: "**")?.lowerBound {
                let value = String(source[source.index(cursor, offsetBy: 2)..<close])
                output += "<strong>\(AcademicSourceCompiler.escapeHTML(value))</strong>"
                cursor = source.index(close, offsetBy: 2)
                continue
            }
            if source[cursor] == "$", let close = source[source.index(after: cursor)...].firstIndex(of: "$") {
                let value = String(source[source.index(after: cursor)..<close])
                output += LaTeXMathMLConverter.render(value, display: false)
                cursor = source.index(after: close)
                continue
            }
            if tail.hasPrefix("[unclear:"), let close = tail.firstIndex(of: "]") {
                let value = String(source[cursor...close])
                output += "<span class=\"unclear\">\(AcademicSourceCompiler.escapeHTML(value))</span>"
                cursor = source.index(after: close)
                continue
            }
            output += AcademicSourceCompiler.escapeHTML(String(source[cursor]))
            cursor = source.index(after: cursor)
        }
        return output
    }

    private func embeddedImage(path: String, alt: String) throws -> String {
        guard !path.contains(".."), !path.hasPrefix("/"), !path.contains("://") else {
            return "<span class=\"unclear\">[blocked image path]</span>"
        }
        let url = assetRoot.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(assetRoot.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else {
            return "<span class=\"unclear\">[missing figure: \(AcademicSourceCompiler.escapeHTML(path))]</span>"
        }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/png"
        let caption = alt == path || alt.hasPrefix("assets/") ? "Source figure" : alt
        return "<figure><img alt=\"\(AcademicSourceCompiler.escapeHTML(caption))\" src=\"data:\(mime);base64,\(data.base64EncodedString())\"><figcaption>\(AcademicSourceCompiler.escapeHTML(caption))</figcaption></figure>"
    }
}

private struct MarkdownLaTeXRenderer {
    func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        var inList = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { output.append("\\begin{itemize}"); inList = true }
                output.append("\\item \(escapeProsePreservingMath(String(line.dropFirst(2))))")
                continue
            }
            if inList { output.append("\\end{itemize}"); inList = false }
            if line == "<div class=\"page-break\"></div>" || line == "<!-- page-break -->" {
                output.append("\\clearpage")
            } else if line.hasPrefix("#### ") {
                output.append("\\paragraph{\(AcademicSourceCompiler.escapeTeX(String(line.dropFirst(5))))}")
            } else if line.hasPrefix("### ") {
                output.append("\\subsubsection{\(AcademicSourceCompiler.escapeTeX(String(line.dropFirst(4))))}")
            } else if line.hasPrefix("## ") {
                output.append("\\subsection{\(AcademicSourceCompiler.escapeTeX(String(line.dropFirst(3))))}")
            } else if line.hasPrefix("# ") {
                output.append("\\section{\(AcademicSourceCompiler.escapeTeX(String(line.dropFirst(2))))}")
            } else if let image = parseImage(line) {
                output.append("\\begin{figure}[htbp]\\centering\\includegraphics[width=.92\\linewidth]{\(AcademicSourceCompiler.escapeTeX(image.path))}\\caption{\(AcademicSourceCompiler.escapeTeX(image.alt))}\\end{figure}")
            } else if line.isEmpty {
                output.append("")
            } else {
                output.append(escapeProsePreservingMath(line) + "\\par")
            }
        }
        if inList { output.append("\\end{itemize}") }
        return output.joined(separator: "\n")
    }

    private func parseImage(_ line: String) -> (alt: String, path: String)? {
        guard line.hasPrefix("!["), let split = line.range(of: "]("), line.hasSuffix(")") else { return nil }
        return (String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound]), String(line[split.upperBound..<line.index(before: line.endIndex)]))
    }

    private func escapeProsePreservingMath(_ source: String) -> String {
        var output = ""
        var prose = ""
        var inMath = false
        var mathDelimiterCount = 0
        var cursor = source.startIndex

        func flushProse() {
            output += AcademicSourceCompiler.escapeTeX(prose)
            prose = ""
        }

        while cursor < source.endIndex {
            if source[cursor] == "$" {
                let next = source.index(after: cursor)
                let count = next < source.endIndex && source[next] == "$" ? 2 : 1
                if !inMath {
                    flushProse()
                    inMath = true
                    mathDelimiterCount = count
                } else if count == mathDelimiterCount {
                    inMath = false
                }
                output += String(repeating: "$", count: count)
                cursor = source.index(cursor, offsetBy: count)
                continue
            }
            if inMath { output.append(source[cursor]) } else { prose.append(source[cursor]) }
            cursor = source.index(after: cursor)
        }
        flushProse()
        return output
    }
}

enum LaTeXMathMLConverter {
    static func render(_ latex: String, display: Bool) -> String {
        let content: String
        if let matrix = renderMatrixIfPresent(latex) {
            content = matrix
        } else {
            content = MathParser(latex).parse()
        }
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display ? "block" : "inline")\" aria-label=\"\(AcademicSourceCompiler.escapeHTML(latex))\"><mrow>\(content)</mrow></math>"
    }

    private static func renderMatrixIfPresent(_ latex: String) -> String? {
        let environments = ["pmatrix", "bmatrix", "matrix", "vmatrix", "array"]
        guard let environment = environments.first(where: { latex.contains("\\begin{\($0)}") }),
              let start = latex.range(of: "\\begin{\(environment)}"),
              let end = latex.range(of: "\\end{\(environment)}", range: start.upperBound..<latex.endIndex) else { return nil }
        var raw = String(latex[start.upperBound..<end.lowerBound])
        if environment == "array" {
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("{"), let close = raw.firstIndex(of: "}") {
                raw = String(raw[raw.index(after: close)...])
            }
        }
        let rows = raw.components(separatedBy: "\\\\").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { row in
            let cells = row.split(separator: "&", omittingEmptySubsequences: false).map { cell in
                "<mtd><mrow>\(MathParser(String(cell)).parse())</mrow></mtd>"
            }.joined()
            return "<mtr>\(cells)</mtr>"
        }.joined()
        let delimiters: (String, String) = environment == "bmatrix" ? ("[", "]") : environment == "vmatrix" ? ("|", "|") : environment == "matrix" || environment == "array" ? ("", "") : ("(", ")")
        return "<mo>\(delimiters.0)</mo><mtable>\(rows)</mtable><mo>\(delimiters.1)</mo>"
    }
}

private final class MathParser {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) { characters = Array(source) }

    func parse() -> String { parseRow(until: nil) }

    private func parseRow(until terminator: Character?) -> String {
        var nodes: [String] = []
        while index < characters.count {
            if let terminator, characters[index] == terminator { index += 1; break }
            if characters[index].isWhitespace { index += 1; continue }
            var atom = parseAtom()
            var subscriptNode: String?
            var superscriptNode: String?
            while index < characters.count, characters[index] == "_" || characters[index] == "^" {
                let marker = characters[index]
                index += 1
                let script = parseScript()
                if marker == "_" { subscriptNode = script } else { superscriptNode = script }
            }
            if let subscriptNode, let superscriptNode {
                atom = "<msubsup>\(atom)<mrow>\(subscriptNode)</mrow><mrow>\(superscriptNode)</mrow></msubsup>"
            } else if let subscriptNode {
                atom = "<msub>\(atom)<mrow>\(subscriptNode)</mrow></msub>"
            } else if let superscriptNode {
                atom = "<msup>\(atom)<mrow>\(superscriptNode)</mrow></msup>"
            }
            nodes.append(atom)
        }
        return nodes.joined()
    }

    private func parseScript() -> String {
        if index < characters.count, characters[index] == "{" {
            index += 1
            return parseRow(until: "}")
        }
        return parseAtom()
    }

    private func parseAtom() -> String {
        guard index < characters.count else { return "" }
        let character = characters[index]
        if character == "{" { index += 1; return "<mrow>\(parseRow(until: "}"))</mrow>" }
        if character == "\\" { return parseCommand() }
        index += 1
        let escaped = AcademicSourceCompiler.escapeHTML(String(character))
        if character.isNumber { return "<mn>\(escaped)</mn>" }
        if character.isLetter { return "<mi>\(escaped)</mi>" }
        return "<mo>\(escaped)</mo>"
    }

    private func parseCommand() -> String {
        index += 1
        let start = index
        while index < characters.count, characters[index].isLetter { index += 1 }
        let command = String(characters[start..<index])
        if command.isEmpty, index < characters.count {
            let escaped = AcademicSourceCompiler.escapeHTML(String(characters[index]))
            index += 1
            return "<mo>\(escaped)</mo>"
        }
        switch command {
        case "frac": return "<mfrac><mrow>\(group())</mrow><mrow>\(group())</mrow></mfrac>"
        case "sqrt": return "<msqrt><mrow>\(group())</mrow></msqrt>"
        case "bar", "overline": return "<mover accent=\"true\"><mrow>\(group())</mrow><mo>¯</mo></mover>"
        case "vec": return "<mover accent=\"true\"><mrow>\(group())</mrow><mo>→</mo></mover>"
        case "boxed": return "<menclose notation=\"box\"><mrow>\(group())</mrow></menclose>"
        case "mathbb": return variant("double-struck")
        case "mathcal": return variant("script")
        case "mathfrak": return variant("fraktur")
        case "mathbf": return variant("bold")
        case "mathrm": return variant("normal")
        case "text": return textGroupPreservingBoundarySpaces()
        case "operatorname": return "<mtext>\(AcademicSourceCompiler.escapeHTML(rawGroup()))</mtext>"
        case "quad": return "<mspace width=\"1em\"/>"
        case "qquad": return "<mspace width=\"2em\"/>"
        case "left", "right": return parseAtom()
        default:
            if let symbol = Self.symbols[command] { return "<mo>\(symbol)</mo>" }
            if let greek = Self.greek[command] { return "<mi>\(greek)</mi>" }
            return "<mtext>\\\(AcademicSourceCompiler.escapeHTML(command))</mtext>"
        }
    }

    private func variant(_ name: String) -> String {
        "<mstyle mathvariant=\"\(name)\"><mrow>\(group())</mrow></mstyle>"
    }

    private func textGroupPreservingBoundarySpaces() -> String {
        let raw = rawGroup()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var nodes: [String] = []
        if raw.first?.isWhitespace == true { nodes.append("<mspace width=\"0.25em\"/>") }
        if !trimmed.isEmpty {
            nodes.append("<mtext>\(AcademicSourceCompiler.escapeHTML(trimmed))</mtext>")
        }
        if raw.last?.isWhitespace == true { nodes.append("<mspace width=\"0.25em\"/>") }
        return nodes.joined()
    }

    private func group() -> String {
        guard index < characters.count, characters[index] == "{" else { return parseAtom() }
        index += 1
        return parseRow(until: "}")
    }

    private func rawGroup() -> String {
        guard index < characters.count, characters[index] == "{" else { return "" }
        index += 1
        let start = index
        var depth = 1
        while index < characters.count, depth > 0 {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" { depth -= 1 }
            index += 1
        }
        return String(characters[start..<max(start, index - 1)])
    }

    private static let symbols: [String: String] = [
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "neq": "≠", "approx": "≈",
        "infty": "∞", "cup": "∪", "cap": "∩", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "supseteq": "⊇", "in": "∈", "notin": "∉", "to": "→",
        "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "iff": "⇔", "implies": "⇒",
        "langle": "⟨", "rangle": "⟩", "checkmark": "✓",
        "sum": "∑", "prod": "∏", "int": "∫",
        "partial": "∂", "nabla": "∇", "times": "×", "cdot": "·", "pm": "±",
        "ldots": "…", "dots": "…", "cdots": "⋯", "mapsto": "↦",
        "forall": "∀", "exists": "∃", "neg": "¬"
    ]
    private static let greek: [String: String] = [
        "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ε", "varepsilon":"ϵ",
        "zeta":"ζ", "eta":"η", "theta":"θ", "vartheta":"ϑ", "iota":"ι", "kappa":"κ",
        "lambda":"λ", "mu":"μ", "nu":"ν", "xi":"ξ", "pi":"π", "rho":"ρ",
        "sigma":"σ", "tau":"τ", "upsilon":"υ", "phi":"φ", "varphi":"ϕ", "chi":"χ",
        "psi":"ψ", "omega":"ω", "Gamma":"Γ", "Delta":"Δ", "Theta":"Θ", "Lambda":"Λ",
        "Xi":"Ξ", "Pi":"Π", "Sigma":"Σ", "Phi":"Φ", "Psi":"Ψ", "Omega":"Ω"
    ]
}
