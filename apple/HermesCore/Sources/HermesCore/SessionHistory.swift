import Foundation

/// watchkit `GET /session_messages` adapter (port of `domain/SessionHistory.kt`): backfill for
/// adopted sessions + the catch-up plan that appends what the desktop said since.
public enum SessionHistory {
    public static let maxMessages = 120
    public static let maxText = 20_000
    public static let summaryPrefix = "🗂 summary · "

    /// `{messages:[{role,content}]}` → rows oldest-first, newest `cap` kept. Malformed JSON throws.
    public static func parse(_ text: String, cap: Int = maxMessages) throws -> [ChatMessage] {
        let arr = try JSON.object(text).array("messages") ?? []
        let rows = arr.compactMap { el -> ChatMessage? in
            guard let o = el as? JSONObject, let role = o["role"] as? String,
                  let raw = o["content"] as? String else { return nil }
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || isNoise(body) { return nil }
            let mapped: ChatMessage.Role
            switch role {
            case "user": mapped = .User
            case "assistant", "summary": mapped = .Hermes
            default: return nil
            }
            let full = role == "summary" ? summaryPrefix + body : body
            return ChatMessage(id: 0, role: mapped, text: full.count > maxText ? String(full.prefix(maxText)) + "…" : full)
        }
        return Array(rows.suffix(max(cap, 0)))
    }

    private static func isNoise(_ body: String) -> Bool {
        body.hasPrefix("[IMPORTANT: Background process") || body.hasPrefix("[SYSTEM: Background process") || body == "—"
    }

    public static func captionLine(count: Int, profile: String) -> String {
        "history · \(count) messages · from \(ProfileLogic.chipLabel(profile))"
    }

    public static func shouldBackfill(sessionId: String, localTranscriptSize: Int) -> Bool {
        !sessionId.trimmingCharacters(in: .whitespaces).isEmpty && localTranscriptSize == 0
    }

    public static func profileProbes(_ primary: String) -> [String] {
        let p = primary.trimmingCharacters(in: .whitespaces)
        let first = p.isEmpty ? ProfileLogic.profileComputer : p
        return first == ProfileLogic.profileComputer ? [first] : [first, ProfileLogic.profileComputer]
    }

    /// Gateway turns the local copy never saw (longest common (role,text) prefix), or nil.
    public static func catchUpPlan(gateway: [ChatMessage], local: [ChatMessage]) -> [ChatMessage]? {
        if gateway.isEmpty || local.isEmpty { return nil }
        let loc = local.filter { $0.role != .System }
        if loc.isEmpty { return nil }
        var i = 0
        while i < gateway.count, i < loc.count, gateway[i].role == loc[i].role, gateway[i].text == loc[i].text { i += 1 }
        if i == 0 || i == gateway.count { return nil }
        return Array(gateway[i...])
    }
}
