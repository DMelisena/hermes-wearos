import Foundation

/// watchkit helper daemon client (server/watchkit/watchkit.mjs), port of `net/Watchkit.kt`:
/// mermaid renders, gateway-host images, state.db session reads/writes, agent key learning.
/// watchkit has its OWN bearer, separate from the gateway's API_SERVER_KEY.
public struct WatchkitClient: Sendable {
    public let baseUrl: String
    let token: String
    let session: URLSession

    public init(baseUrl: String, token: String, session: URLSession = HermesAPI.defaultSession) {
        self.baseUrl = ProfileLogic.trimBase(baseUrl)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func url(_ path: String, _ query: [String: String] = [:]) throws -> URL {
        guard var c = URLComponents(string: baseUrl + "/" + path) else { throw ApiError(code: 0, message: "bad watchkit url") }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let u = c.url else { throw ApiError(code: 0, message: "bad watchkit url") }
        return u
    }

    func data(_ u: URL, body: JSONObject? = nil, auth: Bool = true, what: String) async throws -> Data {
        var r = URLRequest(url: u)
        if auth { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpMethod = "POST"
            r.httpBody = JSON.body(body)
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), !d.isEmpty else {
            throw ApiError(code: code, message: "\(what) \(code): \(String(decoding: d.prefix(160), as: UTF8.self))")
        }
        return d
    }

    func text(_ u: URL, body: JSONObject? = nil, what: String) async throws -> String {
        String(decoding: try await data(u, body: body, what: what), as: UTF8.self)
    }

    /// POST /render/mermaid → PNG bytes.
    public func renderMermaid(_ code: String, width: Int = 400) async throws -> Data {
        try await data(try url("render/mermaid"), body: ["code": code, "width": width], what: "render")
    }

    /// Absolute gateway-host path via `/img` (bearer), or an http(s) URL fetched direct — the
    /// bearer is never sent to a public URL.
    public func image(_ target: String, width: Int = 0) async throws -> Data {
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            guard let u = URL(string: target) else { throw ApiError(code: 0, message: "bad image url") }
            return try await data(u, auth: false, what: "img")
        }
        var q = ["path": target]
        if width > 0 { q["width"] = String(width) }
        return try await data(try url("img", q), what: "img")
    }

    public func agents() async throws -> [String] {
        try GatewaySessions.parseAgents(try await text(try url("agents"), what: "agents"))
    }

    public struct AgentKey: Sendable { public let profile: String; public let hasKey: Bool; public let key: String }

    public func agentKeys() async throws -> [AgentKey] {
        let obj = try JSON.object(try await text(try url("agent_keys"), what: "agent_keys"))
        return (obj.array("agents") ?? []).compactMap { el in
            guard let o = el as? JSONObject, let p = o.str("profile") else { return nil }
            return AgentKey(profile: p, hasKey: o.bool("has_key") ?? false, key: o.str("key") ?? "")
        }
    }

    public func search(_ query: String, profile: String) async throws -> [SessionHit] {
        let obj = try JSON.object(try await text(try url("search", ["q": query, "profile": profile, "limit": "8"]), what: "search"))
        return (obj.array("data") ?? []).compactMap { el in
            guard let o = el as? JSONObject, let id = o.str("id") else { return nil }
            return SessionHit(id: id, title: o.str("title") ?? id, profile: o.str("profile") ?? profile,
                              snippet: o.str("snippet") ?? "", source: .gateway,
                              lastActiveMs: Int64((o.double("last_active") ?? 0) * 1000),
                              hits: o.int("hits") ?? 0, titleMatch: o.bool("title_match") ?? false)
        }
    }

    public func sessionsJson(profile: String, limit: Int = GatewaySessions.maxRows, archived: Bool = false) async throws -> String {
        var q = ["profile": profile, "limit": String(min(max(limit, 1), GatewaySessions.maxRows))]
        if archived { q["archived"] = "1" }
        return try await text(try url("sessions", q), what: "sessions")
    }

    public func sessionMessagesJson(profile: String, sessionId: String, limit: Int = SessionHistory.maxMessages) async throws -> String {
        try await text(try url("session_messages", ["profile": profile, "session_id": sessionId,
                                                   "limit": String(min(max(limit, 1), SessionHistory.maxMessages))]),
                       what: "session_messages")
    }

    public struct ForkResult: Sendable { public let id: String; public let title: String; public let copiedMessages: Int }

    public func forkSession(fromProfile: String, sessionId: String, toProfile: String, newId: String) async throws -> ForkResult {
        let obj = try JSON.object(try await text(try url("session_fork"),
                                                 body: ["profile": fromProfile, "session_id": sessionId, "to_profile": toProfile, "new_id": newId],
                                                 what: "fork"))
        return ForkResult(id: obj.str("id") ?? "", title: obj.str("title") ?? "", copiedMessages: obj.int("copied_messages") ?? 0)
    }

    public func archiveSession(profile: String, sessionId: String, archived: Bool) async throws {
        _ = try await data(try url("session_archive"), body: ["profile": profile, "session_id": sessionId, "archived": archived ? 1 : 0], what: "archive")
    }

    public func deleteSession(profile: String, sessionId: String) async throws -> Int {
        let obj = try JSON.object(try await text(try url("session_delete"), body: ["profile": profile, "session_id": sessionId], what: "delete"))
        return obj.int("messages") ?? 0
    }

    public func health() async throws -> String {
        let t = String(decoding: try await data(try url("health"), auth: false, what: "watchkit health"), as: UTF8.self)
        guard let obj = try? JSON.object(t) else { return "ok (unparsed)" }
        return "ok · watchkit v\(obj.str("version") ?? "?") · up \(obj.str("uptime_s") ?? "?")s"
    }
}
