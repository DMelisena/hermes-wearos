import Foundation

/// One decoded `/v1/runs/{id}/events` frame (Hermes 0.21.7 wire, see HermesAPI header).
public enum RunEvent: Equatable {
    case delta(String)
    case interim(String)
    case toolStarted(String)
    case toolCompleted
    case approval(ApprovalInfo)
    /// nil output → settle with whatever streamed live.
    case completed(String?)
    case failed(String)
    case cancelled
    case ignored

    public static func parse(runId: String, data: String) -> RunEvent {
        guard let obj = try? JSON.object(data) else { return .ignored }
        switch obj.str("event") {
        case "message.delta": return obj.str("delta").map(RunEvent.delta) ?? .ignored
        case "message.interim":
            if obj.bool("already_streamed") == true { return .ignored }
            return obj.str("text").map(RunEvent.interim) ?? .ignored
        case "tool.started": return .toolStarted(obj.str("tool") ?? "tool")
        case "tool.completed": return .toolCompleted
        case "approval.request":
            let q = obj.str("command") ?? obj.str("question") ?? obj.str("message") ?? "Approve this action?"
            return .approval(ApprovalInfo(runId: runId, requestId: obj.str("request_id") ?? obj.str("id"),
                                          question: q, choices: obj.choiceNames()))
        case "run.completed": return .completed(obj.str("output"))
        case "run.failed": return .failed(obj.str("error") ?? obj.str("turn_exit_reason") ?? "run failed")
        case "run.cancelled": return .cancelled
        default: return .ignored
        }
    }
}

/// Minimal Server-Sent Events framing: `data:` lines accumulate, a blank line dispatches,
/// `:` lines are keepalive comments. Fed line by line (blank lines included).
public struct SSEParser {
    private var data: [String] = []
    public init() {}

    public mutating func feed(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { data.removeAll() }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var v = line.dropFirst(5)
            if v.hasPrefix(" ") { v = v.dropFirst() }
            data.append(String(v))
        }
        return nil
    }

    /// Stream ended: a final frame without its trailing blank line still counts.
    public mutating func finish() -> String? { feed("") }
}
