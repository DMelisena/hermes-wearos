import Foundation
import HermesCore

/// Chat registry, local-first (port of `data/ChatStore.kt`): the watch owns the list, the gateway
/// only supplies titles. Registry + active id in one JSON file; per-chat transcripts as separate
/// files written atomically and capped to the newest `maxTranscript` messages.
@MainActor
final class ChatStore: ObservableObject {
    static let maxChats = 30
    static let maxTranscript = 50

    @Published private(set) var chats: [ChatMeta] = []
    @Published private(set) var activeId = ""

    private struct Registry: Codable {
        var chats: [ChatMeta]
        var active: String
    }

    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: registryURL), let r = try? JSONDecoder().decode(Registry.self, from: d) {
            chats = r.chats
            activeId = r.chats.contains { $0.id == r.active } ? r.active : (r.chats.max { $0.updatedAt < $1.updatedAt }?.id ?? "")
        }
    }

    private var registryURL: URL { dir.appendingPathComponent("chats.json") }
    private func transcriptURL(_ id: String) -> URL { dir.appendingPathComponent("transcripts/\(id).json") }

    func get(_ id: String) -> ChatMeta? { chats.first { $0.id == id } }

    func draft(label: String?, profile: String) -> ChatMeta {
        ChatMeta(id: shortId(), sessionTitle: ProfileLogic.newSessionId(profile),
                 label: label?.trimmingCharacters(in: .whitespaces) ?? "", profile: profile)
    }

    /// Chat that ADOPTS an existing gateway session id.
    func draft(adopting sessionTitle: String, label: String?, profile: String) -> ChatMeta {
        ChatMeta(id: shortId(), sessionTitle: sessionTitle, label: label?.trimmingCharacters(in: .whitespaces) ?? "", profile: profile)
    }

    func addActive(_ meta: ChatMeta) {
        chats = [meta] + chats.filter { $0.id != meta.id }
        activeId = meta.id
        evict()
        persist()
    }

    func setActive(_ id: String) {
        guard get(id) != nil else { return }
        activeId = id
        update(id) { $0.updatedAt = nowMs() }
    }

    func update(_ id: String, _ transform: (inout ChatMeta) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        transform(&chats[i])
        persist()
    }

    func rename(_ id: String, _ label: String) {
        update(id) { $0.label = label.trimmingCharacters(in: .whitespaces); $0.updatedAt = nowMs() }
    }

    /// Never the active chat — the caller switches first.
    func delete(_ id: String) {
        guard activeId != id else { return }
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: transcriptURL(id))
        persist()
    }

    private func evict() {
        while chats.count > Self.maxChats,
              let victim = chats.filter({ $0.id != activeId }).min(by: { $0.updatedAt < $1.updatedAt }) {
            chats.removeAll { $0.id == victim.id }
            try? FileManager.default.removeItem(at: transcriptURL(victim.id))
        }
    }

    private func persist() {
        guard let d = try? JSONEncoder().encode(Registry(chats: chats, active: activeId)) else { return }
        try? d.write(to: registryURL, options: .atomic)
    }

    func loadTranscript(_ id: String) -> [ChatMessage] {
        guard let d = try? Data(contentsOf: transcriptURL(id)) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: d)) ?? []
    }

    func saveTranscript(_ id: String, _ messages: [ChatMessage]) {
        guard !id.isEmpty, let d = try? JSONEncoder().encode(Array(messages.suffix(Self.maxTranscript))) else { return }
        try? d.write(to: transcriptURL(id), options: .atomic)
    }
}
