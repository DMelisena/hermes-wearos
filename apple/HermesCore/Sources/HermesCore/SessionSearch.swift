import Foundation

public struct SessionHit: Equatable, Identifiable, Sendable {
    public enum Source: Sendable { case watch, gateway }
    public var id: String
    public var title: String
    public var profile: String
    public var snippet: String
    public var source: Source
    public var watchChatId: String = ""
    public var lastActiveMs: Int64 = 0
    public var hits: Int = 0
    public var titleMatch: Bool = false

    public init(id: String, title: String, profile: String, snippet: String, source: Source,
                watchChatId: String = "", lastActiveMs: Int64 = 0, hits: Int = 0, titleMatch: Bool = false) {
        self.id = id
        self.title = title
        self.profile = profile
        self.snippet = snippet
        self.source = source
        self.watchChatId = watchChatId
        self.lastActiveMs = lastActiveMs
        self.hits = hits
        self.titleMatch = titleMatch
    }
}

/// Two-pass session search (port of `domain/SessionSearch.kt`, SPEC §12.4).
public enum SessionSearch {
    public static let maxResults = 14

    public static func matches(_ text: String, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && text.range(of: q, options: .caseInsensitive) != nil
    }

    public static func preview(_ text: String, _ query: String, radius: Int = 48) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(radius * 2))
        }
        guard let r = text.range(of: q, options: .caseInsensitive) else {
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
            return String(first.prefix(radius * 2))
        }
        let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var out = ""
        if start > text.startIndex { out += "…" }
        out += text[start..<end]
        if end < text.endIndex { out += "…" }
        return out.replacingOccurrences(of: "\n", with: " ")
    }

    public static func localHits(_ chats: [ChatMeta], _ query: String, transcript: (String) -> [ChatMessage]) -> [SessionHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return [] }
        return chats.compactMap { c in
            let titleHit = matches(c.label, q) || matches(c.sessionTitle, q)
            var snippet = titleHit ? c.label : ""
            if !titleHit {
                guard let m = transcript(c.id).reversed().first(where: { matches($0.text, q) }) else { return nil }
                snippet = preview(m.text, q)
            }
            return SessionHit(id: c.id, title: c.displayLabel, profile: c.profile, snippet: snippet, source: .watch,
                              watchChatId: c.id, lastActiveMs: c.updatedAt, hits: titleHit ? 2 : 1, titleMatch: titleHit)
        }
    }

    public static func merge(local: [SessionHit], gateway: [SessionHit], cap: Int = maxResults) -> [SessionHit] {
        var order: [String] = []
        var by: [String: SessionHit] = [:]
        for h in local where by[h.id] == nil { order.append(h.id); by[h.id] = h }
        for h in gateway {
            if var e = by[h.id] {
                if e.snippet.trimmingCharacters(in: .whitespaces).isEmpty { e.snippet = h.snippet }
                e.hits = max(e.hits, h.hits)
                e.titleMatch = e.titleMatch || h.titleMatch
                e.lastActiveMs = max(e.lastActiveMs, h.lastActiveMs)
                by[h.id] = e
            } else {
                order.append(h.id)
                by[h.id] = h
            }
        }
        let sorted = order.compactMap { by[$0] }.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.titleMatch != y.titleMatch { return x.titleMatch }
            if x.hits != y.hits { return x.hits > y.hits }
            if x.lastActiveMs != y.lastActiveMs { return x.lastActiveMs > y.lastActiveMs }
            return a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(cap))
    }
}
