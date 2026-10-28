import Foundation

/// One Hermes gateway the watch can reach (SPEC §11). Endpoints are ORDERED host:port bases with
/// no `/p/<agent>` suffix; the first is the DEFAULT entry, the rest failover fallbacks.
/// `agentKeys` is the per-profile `API_SERVER_KEY` map (SPEC §12.2).
public struct Gateway: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var apiEndpoints: [String]
    public var watchkitEndpoints: [String]
    public var token: String
    public var agentKeys: [String: String]

    public init(id: String, label: String, apiEndpoints: [String], watchkitEndpoints: [String],
                token: String = "", agentKeys: [String: String] = [:]) {
        self.id = id
        self.label = label
        self.apiEndpoints = apiEndpoints
        self.watchkitEndpoints = watchkitEndpoints
        self.token = token
        self.agentKeys = agentKeys
    }

    // Missing fields decode to defaults so a newer blob never bricks an older build (and back).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        apiEndpoints = try c.decodeIfPresent([String].self, forKey: .apiEndpoints) ?? []
        watchkitEndpoints = try c.decodeIfPresent([String].self, forKey: .watchkitEndpoints) ?? []
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        agentKeys = try c.decodeIfPresent([String: String].self, forKey: .agentKeys) ?? [:]
    }

    public var primaryApi: String { apiEndpoints.first ?? "" }
    public var primaryWatchkit: String { watchkitEndpoints.first ?? "" }

    /// This agent's key on this gateway, falling back to the gateway token (SPEC §12.2 order).
    public func keyFor(_ agent: String) -> String {
        if let k = agentKeys[agent]?.trimmingCharacters(in: .whitespaces), !k.isEmpty { return k }
        return token.trimmingCharacters(in: .whitespaces)
    }
}

public enum GatewayModel {
    /// First-run PLACEHOLDERS — replace in Settings ▸ Gateways with your own host.
    public static let seedId = "hermes"
    public static let tailnetApi = "http://hermes.tailnet.ts.net:8642"
    public static let lanApi = "http://192.168.1.50:8642"
    public static let tailnetWatchkit = "http://hermes.tailnet.ts.net:8651"
    public static let lanWatchkit = "http://192.168.1.50:8651"

    public static func seed(token: String = "") -> Gateway {
        Gateway(id: seedId, label: seedId, apiEndpoints: [tailnetApi, lanApi],
                watchkitEndpoints: [tailnetWatchkit, lanWatchkit], token: token.trimmingCharacters(in: .whitespaces))
    }

    /// Trim + drop trailing slash + strip a `/p/<agent>` suffix.
    public static func normalizeEndpoint(_ url: String) -> String {
        let u = ProfileLogic.trimBase(url)
        guard !u.isEmpty, let scheme = u.range(of: "://"),
              let from = u[scheme.upperBound...].firstIndex(of: "/"),
              let p = u.range(of: "/p/", range: from..<u.endIndex) else { return u }
        return ProfileLogic.trimBase(String(u[..<p.lowerBound]))
    }

    /// The profile-scoped base every network consumer uses: endpoint + `/p/<agent>`.
    public static func apiBase(_ endpoint: String, profile: String) -> String {
        let e = normalizeEndpoint(endpoint)
        guard !e.isEmpty, ProfileLogic.isValidProfile(profile) else { return e }
        return "\(e)/p/\(profile)"
    }

    public static func encode(_ list: [Gateway]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Garbage/blank decodes to empty — callers then re-seed.
    public static func decode(_ raw: String) -> [Gateway] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return (try? JSONDecoder().decode([Gateway].self, from: Data(raw.utf8))) ?? []
    }

    /// Agent key → gateway token → mirror token (SPEC §12.2).
    public static func tokenFor(_ gateway: Gateway?, agent: String, mirrorToken: String = "") -> String {
        if let k = gateway?.keyFor(agent), !k.isEmpty { return k }
        return mirrorToken.trimmingCharacters(in: .whitespaces)
    }

    private static func authority(_ u: String) -> (scheme: String, authority: String)? {
        guard let scheme = u.range(of: "://") else { return nil }
        let rest = u[scheme.upperBound...]
        let auth = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let noUser = auth.split(separator: "@").last.map(String.init) ?? auth
        return (String(u[..<scheme.upperBound]), noUser)
    }

    /// Same host, watchkit port convention (:8651).
    public static func derivedWatchkit(_ apiEndpoint: String) -> String {
        guard let (scheme, auth) = authority(normalizeEndpoint(apiEndpoint)) else { return "" }
        let host = auth.split(separator: ":").first.map(String.init) ?? ""
        return host.isEmpty ? "" : "\(scheme)\(host):8651"
    }

    /// Stable id from a URL host: `http://vps.example.com:8642` → `vps-example-com`.
    public static func hostId(_ url: String) -> String {
        let u = normalizeEndpoint(url)
        let auth = authority(u)?.authority ?? u
        var host = auth
        if let colon = auth.lastIndex(of: ":") { host = String(auth[..<colon]) }
        if host.isEmpty { host = auth }
        let mapped = String(host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let id = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return id.isEmpty ? "gateway" : id
    }

    public struct InvalidGateway: Error {}

    /// CRUD: replace by id, else append. Throws when no API endpoint survives cleaning.
    public static func upsert(_ list: [Gateway], _ gw: Gateway) throws -> [Gateway] {
        func clean(_ eps: [String]) -> [String] {
            var seen = Set<String>()
            return eps.map(normalizeEndpoint).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        var g = gw
        g.apiEndpoints = clean(gw.apiEndpoints)
        g.watchkitEndpoints = clean(gw.watchkitEndpoints)
        g.token = gw.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.apiEndpoints.isEmpty else { throw InvalidGateway() }
        if g.id.isEmpty { g.id = hostId(g.primaryApi) }
        let label = gw.label.trimmingCharacters(in: .whitespaces)
        g.label = label.isEmpty ? g.id : label
        var out = list
        if let i = out.firstIndex(where: { $0.id == g.id }) { out[i] = g } else { out.append(g) }
        return out
    }

    public static func remove(_ list: [Gateway], id: String) -> [Gateway] { list.filter { $0.id != id } }

    public static func selectedAfterRemove(_ selected: String, list: [Gateway], removedId: String) -> String {
        selected != removedId ? selected : (list.first { $0.id != removedId }?.id ?? "")
    }
}
