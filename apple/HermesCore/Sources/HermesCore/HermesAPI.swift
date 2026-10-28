import Foundation

/// Hermes API server (runs surface), port of `net/HermesApi.kt`. Wire contract (Hermes 0.21.7):
///  - POST /v1/runs {input, session_id, model} + `Idempotency-Key` → {run_id, status, replayed}
///  - GET  /v1/runs/{id}/events → SSE `data: {"event": ...}` frames (see `RunEvent`)
///  - GET  /v1/runs/{id} → status; terminal snapshots carry `output` (resume-safe final answer)
///  - POST /v1/runs/{id}/approval|stop|steer · GET /v1/health|capabilities · /api/sessions…
public struct HermesAPI: Sendable {
    /// The gateway's virtual model alias = "serve this profile's configured default".
    public static let virtualModel = "hermes-agent"

    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 45 // events stream: server keepalive every 10 s
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    public let baseUrl: String
    let token: String
    let session: URLSession

    public init(baseUrl: String, token: String, session: URLSession = HermesAPI.defaultSession) {
        self.baseUrl = baseUrl
        self.token = token
        self.session = session
    }

    func request(_ path: String, body: JSONObject? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = URL(string: baseUrl + path) else { throw ApiError(code: 0, message: "bad url \(baseUrl)\(path)") }
        var r = URLRequest(url: url)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = JSON.body(body)
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Body text on 2xx; ApiError(code) otherwise.
    func call(_ r: URLRequest, what: String) async throws -> String {
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else { throw ApiError(code: code, message: "\(what) \(code): \(text.prefix(160))") }
        return text
    }

    public struct RunAccepted: Equatable, Sendable {
        public let runId: String
        public let status: String
        public let replayed: Bool
    }

    /// Durably idempotent: retrying with the same key never starts a second run.
    public func submitRun(input: String, sessionId: String, idempotencyKey: String, model: String = virtualModel) async throws -> RunAccepted {
        let r = try request("/v1/runs", body: ["input": input, "session_id": sessionId, "model": model],
                            headers: ["Idempotency-Key": idempotencyKey])
        let obj = try JSON.object(try await call(r, what: "run submit"))
        guard let id = obj.str("run_id") else { throw ApiError(code: 200, message: "no run_id") }
        return RunAccepted(runId: id, status: obj.str("status") ?? "started",
                           replayed: obj.bool("replayed") ?? (obj.str("replayed") == "true"))
    }

    public struct RunSnapshot: Sendable {
        public let status: String
        public let output: String?
        public let approval: ApprovalInfo?
    }

    public func runStatus(_ runId: String) async throws -> RunSnapshot {
        let obj = try JSON.object(try await call(try request("/v1/runs/\(runId)"), what: "run status"))
        let ap = obj.object("approval").map {
            ApprovalInfo(runId: runId, requestId: $0.str("request_id") ?? $0.str("id"),
                         question: $0.str("command") ?? "Approve?", choices: $0.choiceNames())
        }
        return RunSnapshot(status: obj.str("status") ?? "unknown", output: obj.str("output"), approval: ap)
    }

    /// SSE event payloads (`data:` bodies) for a run until the server closes the stream.
    /// Bytes are split by hand: `AsyncLineSequence` swallows the blank lines SSE dispatches on.
    public func events(_ runId: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var r = try request("/v1/runs/\(runId)/events")
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    r.timeoutInterval = 45
                    let (bytes, resp) = try await session.bytes(for: r)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else { throw ApiError(code: code, message: "events \(code)") }
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    for try await b in bytes {
                        if b == UInt8(ascii: "\n") {
                            if let ev = parser.feed(String(decoding: line, as: UTF8.self)) { cont.yield(ev) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(b)
                        }
                    }
                    if !line.isEmpty, let ev = parser.feed(String(decoding: line, as: UTF8.self)) { cont.yield(ev) }
                    if let ev = parser.finish() { cont.yield(ev) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func respondApproval(runId: String, choice: String, requestId: String?) async throws {
        var body: JSONObject = ["choice": choice]
        if let requestId { body["request_id"] = requestId }
        _ = try await call(try request("/v1/runs/\(runId)/approval", body: body), what: "approval")
    }

    public func stopRun(_ runId: String) async throws -> String {
        String(try await call(try request("/v1/runs/\(runId)/stop", body: [:]), what: "run stop").prefix(120))
    }

    /// `/steer` (cap `run_steer`): guidance into the run in flight. 404/409 = run already ended.
    public func steerRun(_ runId: String, text: String) async throws -> String {
        String(try await call(try request("/v1/runs/\(runId)/steer", body: ["input": text]), what: "run steer").prefix(160))
    }

    /// Gateway fork (cap `session_fork`) → NEW session id (full history copied).
    public func forkSession(_ sessionId: String) async throws -> String {
        let obj = try JSON.object(try await call(try request("/api/sessions/\(sessionId)/fork", body: [:]), what: "session fork"))
        guard let s = obj.object("session"), let id = s.str("id") else { throw ApiError(code: 200, message: "session fork: no id") }
        return id
    }

    /// `GET /v1/health` → "ok · hermes-agent v0.21.7".
    public func health() async throws -> String {
        let text = try await call(try request("/v1/health"), what: "health")
        guard let obj = try? JSON.object(text) else { return "ok (unparsed: \(text.prefix(60)))" }
        return "\(obj.str("status") ?? "ok") · \(obj.str("platform") ?? "hermes") v\(obj.str("version") ?? "?")"
    }

    /// Feature flags; booleans only.
    public func capabilities() async throws -> [String: Bool] {
        let obj = try JSON.object(try await call(try request("/v1/capabilities"), what: "capabilities"))
        var out: [String: Bool] = [:]
        for k in obj.keys { if let b = obj.bool(k) { out[k] = b } }
        return out
    }

    public func sessionsJson() async throws -> String {
        try await call(try request("/api/sessions"), what: "sessions")
    }

    public func listSessions() async throws -> [GatewaySessions.Info] {
        try GatewaySessions.parse(try await sessionsJson())
    }

    public func modelOptions() async throws -> ModelCatalog.Catalog {
        ModelCatalog.parse(try JSON.object(try await call(try request("/api/model/options"), what: "model options")))
    }

    /// The model this session last ran on; nil = nothing stamped (or unreadable).
    public func sessionModel(_ sessionId: String) async -> String? {
        let enc = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        guard let r = try? request("/api/sessions/\(enc)"),
              let text = try? await call(r, what: "session"),
              let obj = try? JSON.object(text) else { return nil }
        let m = (obj.object("session") ?? obj).str("model")
        return m == HermesAPI.virtualModel ? nil : m
    }
}
