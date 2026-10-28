import Foundation

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case User, Hermes, System }
    public var id: Int64
    public var role: Role
    public var text: String
    public init(id: Int64, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct ApprovalInfo: Equatable, Sendable {
    public let runId: String
    public let requestId: String?
    public let question: String
    public let choices: [String]
    public init(runId: String, requestId: String?, question: String, choices: [String]) {
        self.runId = runId
        self.requestId = requestId
        self.question = question
        self.choices = choices
    }
}

/// One watch chat = one gateway session (`sessionTitle` is the Hermes `session_id`).
public struct ChatMeta: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionTitle: String
    public var label: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var lastRunId: String
    public var pendingAttention: Bool
    public var profile: String
    /// Per-chat model pick (SPEC §12.7); "" = gateway default.
    public var model: String

    public init(id: String, sessionTitle: String, label: String = "", createdAt: Int64 = nowMs(),
                updatedAt: Int64 = nowMs(), lastRunId: String = "", pendingAttention: Bool = false,
                profile: String = ProfileLogic.fallbackAgent, model: String = "") {
        self.id = id
        self.sessionTitle = sessionTitle
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunId = lastRunId
        self.pendingAttention = pendingAttention
        self.profile = profile
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionTitle = try c.decode(String.self, forKey: .sessionTitle)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        lastRunId = try c.decodeIfPresent(String.self, forKey: .lastRunId) ?? ""
        pendingAttention = try c.decodeIfPresent(Bool.self, forKey: .pendingAttention) ?? false
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ProfileLogic.fallbackAgent
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    }

    public var displayLabel: String { label.isEmpty ? sessionTitle : label }
}

public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

public func shortId() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

/// Notification deep link (port of `NotificationDeepLink.kt`): a chat on another agent switches first.
public enum NotificationDeepLink {
    public enum Route: Equatable { case open, switchThenOpen(String) }
    public static func plan(currentProfile: String, chatProfile: String, chatKnown: Bool) -> Route {
        if !chatKnown || chatProfile.isEmpty || chatProfile == currentProfile { return .open }
        return .switchThenOpen(chatProfile)
    }
}

public enum SessionManage {
    public static func chatLabel(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "fork" }
        if t.hasSuffix("(fork)") { return t }
        return "\(String(t.prefix(40)).trimmingCharacters(in: .whitespaces)) (fork)"
    }

    public static func localMirror(_ chats: [ChatMeta], sessionId: String) -> ChatMeta? {
        chats.first { $0.sessionTitle == sessionId }
    }
}
