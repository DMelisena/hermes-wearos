import Foundation

/// Block-level markdown for the wrist (port of `ui/md/WatchMarkdown.kt` block rules). Inline
/// styling (`**bold**`, `` `code` ``, links) stays as raw text here; the SwiftUI side hands it
/// to `AttributedString(markdown:)`, so anything unparseable degrades to literal text.
public enum MdBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(text: String, indent: Int)
    case numbered(n: Int, text: String)
    case quote(String)
    case code(lang: String, code: String)
    case mermaid(String)
    /// Image-ONLY line `![alt](target)` or `MEDIA:/abs/path.png` (SPEC §5 F6).
    case image(alt: String, target: String)
    /// Tables degrade to `· col: cell` lines — a wide grid is unreadable on a watch.
    case table([String])
    case hr
}

public enum WatchMarkdown {
    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let heading = re("^(#{1,6})\\s+(.*?)(?:\\s+#+\\s*)?$")
    private static let hrRe = re("^\\s{0,3}(-{3,}|\\*{3,}|_{3,})\\s*$")
    private static let quoteRe = re("^\\s*>\\s?(.*)$")
    private static let bulletRe = re("^(\\s*)([-*+])\\s+(.*)$")
    private static let numberedRe = re("^\\s*(\\d{1,9})[.)]\\s+(.*)$")
    private static let imageRe = re("^\\s*!\\[([^\\]]*)\\]\\(\\s*([^()\\s]+)(?:\\s+[\"'][^\"']*[\"'])?\\s*\\)\\s*$")
    private static let mediaRe = re("^\\s*MEDIA:\\s*(\\S+\\.(?:png|jpe?g|webp|gif))\\s*$", .caseInsensitive)
    private static let sepRe = re("^\\s*\\|?\\s*:?-{2,}:?\\s*(\\|\\s*:?-{2,}:?\\s*)*\\|?\\s*$")

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let rg = m.range(at: i)
            return rg.location == NSNotFound ? "" : ns.substring(with: rg)
        }
    }

    private static func isSeparator(_ line: String) -> Bool { groups(sepRe, line) != nil }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return false }
        return t.hasPrefix("|") || t.filter { $0 == "|" }.count >= 2
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func parse(_ text: String) -> [MdBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var out: [MdBlock] = []
        var para: [String] = []
        func flush() {
            let joined = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            para.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); i += 1; continue }

            // Fenced code (unclosed fence = everything left, stream-safe).
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fc = t.first!
                let flen = t.prefix { $0 == fc }.count
                let info = t.dropFirst(flen).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    let lt = lines[j].trimmingCharacters(in: .whitespaces)
                    if lt.count >= flen && lt.allSatisfy({ $0 == fc }) { closed = true; break }
                    body.append(lines[j])
                    j += 1
                }
                let code = body.joined(separator: "\n")
                out.append(info.lowercased().hasPrefix("mermaid") ? .mermaid(code) : .code(lang: info, code: code))
                i = closed ? j + 1 : j
                continue
            }
            if let g = groups(heading, line) {
                flush()
                out.append(.heading(level: g[1].count, text: g[2].trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if groups(hrRe, t) != nil { flush(); out.append(.hr); i += 1; continue }
            if groups(quoteRe, line) != nil {
                flush()
                var inner: [String] = []
                while i < lines.count, let g = groups(quoteRe, lines[i]) { inner.append(g[1]); i += 1 }
                out.append(.quote(inner.joined(separator: "\n")))
                continue
            }
            if let g = groups(bulletRe, line) {
                flush()
                out.append(.bullet(text: g[3], indent: min(g[1].count / 2, 3)))
                i += 1; continue
            }
            if let g = groups(numberedRe, line) {
                flush()
                out.append(.numbered(n: min(Int(g[1]) ?? 1, 999), text: g[2]))
                i += 1; continue
            }
            if looksLikeTableRow(line) {
                flush()
                var rows: [(cells: [String], sep: Bool)] = []
                while i < lines.count, looksLikeTableRow(lines[i]) {
                    rows.append((cells(lines[i]), isSeparator(lines[i])))
                    i += 1
                }
                let data = rows.filter { !$0.sep }
                let hasHeader = rows.count > 1 && rows[1].sep && !data.isEmpty
                let header = hasHeader ? data[0].cells : []
                let body = hasHeader ? Array(data.dropFirst()) : data
                var outLines: [String] = []
                for row in body {
                    for (c, cell) in row.cells.enumerated() where !cell.isEmpty {
                        let label = c < header.count && !header[c].isEmpty ? header[c] : nil
                        outLines.append(label.map { "· \($0): \(cell)" } ?? "· \(cell)")
                    }
                }
                if outLines.isEmpty { outLines = header.filter { !$0.isEmpty }.map { "· \($0)" } }
                if !outLines.isEmpty { out.append(.table(outLines)) }
                continue
            }
            if let g = groups(imageRe, line) {
                flush()
                out.append(.image(alt: g[1].trimmingCharacters(in: .whitespaces), target: g[2]))
                i += 1; continue
            }
            if let g = groups(mediaRe, line) {
                flush()
                out.append(.image(alt: g[1].split(separator: "/").last.map(String.init) ?? g[1], target: g[1]))
                i += 1; continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    /// Speakable text for TTS: fences/images dropped, inline markers stripped.
    public static func speakable(_ text: String) -> String {
        parse(text).compactMap { b -> String? in
            switch b {
            case .heading(_, let t), .paragraph(let t), .quote(let t), .bullet(let t, _), .numbered(_, let t):
                return t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "__", with: "")
            case .table(let lines): return lines.joined(separator: ". ")
            case .code, .mermaid, .image, .hr: return nil
            }
        }.joined(separator: "\n")
    }
}
