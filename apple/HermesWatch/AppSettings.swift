import Foundation
import HermesCore
import Security

/// Everything the watch is configured with, all editable in-app (SPEC §4). Secrets (gateway
/// registry with its tokens/agent keys, watchkit bearer) live in the Keychain; plain prefs in
/// UserDefaults. The failover winner is in-memory only ("for the session").
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    let resolver = EndpointResolver()

    @Published private(set) var gateways: [Gateway]
    @Published private(set) var selectedGatewayId: String
    /// Active agent (`/p/<profile>`), remembered across launches.
    @Published private(set) var profile: String
    @Published private(set) var endpointStatus = EndpointResolver.Status()
    @Published var watchkitToken: String { didSet { Keychain.set(watchkitToken, for: "watchkit_token") } }
    @Published var voiceOut: Bool { didSet { defaults.set(voiceOut, forKey: "voice_out") } }
    @Published var markdown: Bool { didSet { defaults.set(markdown, forKey: "markdown_rendering") } }
    @Published private(set) var agentsCache: [String]

    init() {
        var list = GatewayModel.decode(Keychain.get("gateways_json"))
        if list.isEmpty { list = [GatewayModel.seed()] }
        gateways = list
        let sel = defaults.string(forKey: "gateway_selected") ?? ""
        selectedGatewayId = list.contains { $0.id == sel } ? sel : list[0].id
        let agent = defaults.string(forKey: "current_agent") ?? ""
        profile = ProfileLogic.isValidProfile(agent) ? agent : ProfileLogic.fallbackAgent
        watchkitToken = Keychain.get("watchkit_token")
        voiceOut = defaults.object(forKey: "voice_out") as? Bool ?? true
        markdown = defaults.object(forKey: "markdown_rendering") as? Bool ?? true
        agentsCache = defaults.stringArray(forKey: "agents_cache") ?? []
        persistGateways()
    }

    var selectedGateway: Gateway? { gateways.first { $0.id == selectedGatewayId } }

    /// Winner (else primary) api endpoint + `/p/<profile>`.
    var baseUrl: String {
        let ep = endpointStatus.gatewayId == selectedGatewayId && !endpointStatus.apiWinner.isEmpty
            ? endpointStatus.apiWinner : (selectedGateway?.primaryApi ?? "")
        return GatewayModel.apiBase(ep, profile: profile)
    }

    var watchkitBase: String {
        endpointStatus.gatewayId == selectedGatewayId && !endpointStatus.watchkitWinner.isEmpty
            ? endpointStatus.watchkitWinner : (selectedGateway?.primaryWatchkit ?? "")
    }

    func token(for agent: String) -> String { GatewayModel.tokenFor(selectedGateway, agent: agent) }

    /// API handle for the ACTIVE agent, signed with THAT agent's key (SPEC §12.2).
    func api(base: String? = nil) -> HermesAPI { HermesAPI(baseUrl: base ?? baseUrl, token: token(for: profile)) }

    var watchkit: WatchkitClient { WatchkitClient(baseUrl: watchkitBase, token: watchkitToken) }

    func ensureEndpoints(force: Bool = false) async {
        guard let gw = selectedGateway else { return }
        endpointStatus = await resolver.ensure(gw, profile: profile, force: force)
    }

    /// Mid-session failover: new profiled base, or nil when nothing better answered.
    func advance(from usedBase: String) async -> String? {
        guard let gw = selectedGateway else { return nil }
        let next = await resolver.advance(from: usedBase, gateway: gw, profile: profile)
        endpointStatus = await resolver.status
        return next
    }

    @discardableResult
    func setProfile(_ agent: String) -> Bool {
        guard ProfileLogic.isValidProfile(agent) else { return false }
        profile = agent
        defaults.set(agent, forKey: "current_agent")
        return true
    }

    // MARK: gateways

    private func persistGateways() { Keychain.set(GatewayModel.encode(gateways), for: "gateways_json") }

    func saveGateway(_ gw: Gateway, select: Bool) throws {
        gateways = try GatewayModel.upsert(gateways, gw)
        persistGateways()
        let id = gw.id.isEmpty ? GatewayModel.hostId(gw.apiEndpoints.first ?? "") : gw.id
        if select || selectedGatewayId.isEmpty { selectGateway(id) }
        if let saved = gateways.first(where: { $0.id == id }), id == selectedGatewayId {
            Task { await resolver.bind(saved, force: true); await ensureEndpoints(force: true) }
        }
    }

    func deleteGateway(_ id: String) {
        let next = GatewayModel.selectedAfterRemove(selectedGatewayId, list: gateways, removedId: id)
        gateways = GatewayModel.remove(gateways, id: id)
        if gateways.isEmpty { gateways = [GatewayModel.seed()] }
        persistGateways()
        selectGateway(gateways.contains { $0.id == next } ? next : gateways[0].id)
    }

    func selectGateway(_ id: String) {
        guard gateways.contains(where: { $0.id == id }) else { return }
        selectedGatewayId = id
        defaults.set(id, forKey: "gateway_selected")
        Task { await ensureEndpoints(force: true) }
    }

    func setAgentKey(_ agent: String, key: String) {
        guard var gw = selectedGateway else { return }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { gw.agentKeys.removeValue(forKey: agent) } else { gw.agentKeys[agent] = k }
        try? saveGateway(gw, select: false)
    }

    /// Learn this box's per-profile keys from watchkit `GET /agent_keys`; unreachable → 0, keys kept.
    func refreshAgentKeys() async -> Int {
        guard var gw = selectedGateway, let rows = try? await watchkit.agentKeys(), !rows.isEmpty else { return 0 }
        for r in rows where !r.key.isEmpty { gw.agentKeys[r.profile] = r.key }
        gateways = (try? GatewayModel.upsert(gateways, gw)) ?? gateways
        persistGateways()
        return gw.agentKeys.count
    }

    // MARK: caches

    func setAgentsCache(_ list: [String]) {
        agentsCache = list
        defaults.set(list, forKey: "agents_cache")
    }

    var sessionsCache: String { defaults.string(forKey: "gw_sessions_json") ?? "" }

    func setSessionsCache(_ text: String) { defaults.set(text, forKey: "gw_sessions_json") }
}

/// Generic-password Keychain wrapper (one service, string values).
enum Keychain {
    private static let service = "dev.hermes.watch"

    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
