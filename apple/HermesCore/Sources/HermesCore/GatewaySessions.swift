import Foundation

/// Parsers for `GET {base}/api/sessions` and watchkit `/sessions` + `/agents` (port of
/// `net/GatewaySessions.kt`). Wire: `{object:"list", data:[{id,title,last_active:<unix s>,message_count}]}`.
public enum GatewaySessions {
    public static let maxRows = 30
    public static let filterAll = ""
    public static let filterArchived = "\u{0}archived"

    public struct Info: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let lastActiveMs: Int64
        public let messages: Int
        public var profile: String
        public var archived: Bool
        public init(id: String, title: String, lastActiveMs: Int64, messages: Int, profile: String = "", archived: Bool = false) {
            self.id = id
            self.title = title
            self.lastActiveMs = lastActiveMs
            self.messages = messages
            self.profile = profile
            self.archived = archived
        }
    }

    /// Parse + newest-first sort; malformed JSON throws.
    public static func parse(_ text: String) throws -> [Info] {
        let data = try JSON.object(text).array("data") ?? []
        return data.compactMap { el -> Info? in
            guard let o = el as? JSONObject, let id = o.str("id") else { return nil }
            let sec = o.double("last_active") ?? 0
            return Info(id: id, title: o.str("title") ?? "", lastActiveMs: Int64(sec * 1000),
                        messages: o.int("message_count") ?? 0, profile: o.str("profile") ?? "",
                        archived: o.bool("archived") ?? false)
        }.sorted { $0.lastActiveMs > $1.lastActiveMs }
    }

    public static func parseProfiled(_ text: String, profile tag: String) throws -> [Info] {
        try parse(text).map { var r = $0; if r.profile.isEmpty { r.profile = tag }; return r }
    }

    /// Dedupe by id preferring profile-tagged then fresher rows; newest-first; capped.
    public static func merge(_ rows: [Info], cap: Int = maxRows) -> [Info] {
        var best: [String: Info] = [:]
        for r in rows {
            if let cur = best[r.id] {
                let curKey = (cur.profile.isEmpty ? 0 : 1, cur.lastActiveMs)
                let newKey = (r.profile.isEmpty ? 0 : 1, r.lastActiveMs)
                if newKey > curKey { best[r.id] = r }
            } else {
                best[r.id] = r
            }
        }
        return Array(best.values.sorted { $0.lastActiveMs > $1.lastActiveMs }.prefix(min(max(cap, 0), maxRows)))
    }

    public static func filterProfile(_ rows: [Info], _ profile: String) -> [Info] {
        profile == filterAll ? rows : rows.filter { $0.profile == profile }
    }

    public static func profilesIn(_ rows: [Info]) -> [String] {
        var seen = Set<String>()
        return rows.map(\.profile).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Cache serialization — the exact wire shape `parse` reads back.
    public static func encode(_ rows: [Info]) -> String {
        let data: [JSONObject] = rows.map {
            ["id": $0.id, "title": $0.title, "last_active": Double($0.lastActiveMs) / 1000.0,
             "message_count": $0.messages, "profile": $0.profile, "archived": $0.archived]
        }
        return String(data: JSON.body(["object": "list", "data": data]), encoding: .utf8) ?? "{}"
    }

    public static func parseAgents(_ text: String) throws -> [String] {
        var seen = Set<String>()
        return (try JSON.object(text).array("agents") ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
