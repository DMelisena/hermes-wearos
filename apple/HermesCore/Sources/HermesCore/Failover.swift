import Foundation

/// Endpoint failover state machine (port of `domain/Failover.kt`, SPEC §11): candidates in list
/// order until one answers health; the winner is sticky for `reprobeMs`; a fallback winner makes
/// the primary retry every `primaryRetryMs`; all-dead keeps the previous winner as a stale pointer.
public final class Failover {
    public static let defaultReprobeMs: Int64 = 300_000
    public static let defaultPrimaryRetryMs: Int64 = 60_000

    public let endpoints: [String]
    private let reprobeMs: Int64
    private let primaryRetryMs: Int64
    private let clock: () -> Int64

    public private(set) var winner: String?
    private var winnerAtMs: Int64 = 0
    private var primaryRetryAtMs: Int64 = 0
    /// Last probe outcome per endpoint — drives the Settings dots.
    public private(set) var lastResult: [String: Bool] = [:]

    public init(endpoints: [String],
                reprobeMs: Int64 = Failover.defaultReprobeMs,
                primaryRetryMs: Int64 = Failover.defaultPrimaryRetryMs,
                clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.endpoints = endpoints
        self.reprobeMs = reprobeMs
        self.primaryRetryMs = primaryRetryMs
        self.clock = clock
    }

    private func norm(_ u: String) -> String { ProfileLogic.trimBase(u) }

    /// What to dial RIGHT NOW: the winner, else the primary.
    public func effective() -> String { winner ?? endpoints.first ?? "" }

    public func isWinner(_ url: String) -> Bool { winner.map { norm($0) == norm(url) } ?? false }

    public func needsProbe(now: Int64? = nil) -> Bool {
        let now = now ?? clock()
        guard let w = winner else { return !endpoints.isEmpty }
        if now - winnerAtMs >= reprobeMs { return true }
        if let p = endpoints.first, norm(w) != norm(p), now >= primaryRetryAtMs { return true }
        return false
    }

    public func probeOrder(now: Int64? = nil) -> [String] {
        let now = now ?? clock()
        guard let primary = endpoints.first else { return [] }
        guard let w = winner else { return endpoints }
        if norm(w) != norm(primary) && now >= primaryRetryAtMs {
            return [primary] + endpoints.filter { norm($0) != norm(primary) }
        }
        return [w] + endpoints.filter { norm($0) != norm(w) }
    }

    public func onSuccess(_ url: String, now: Int64? = nil) {
        winner = url
        winnerAtMs = now ?? clock()
        lastResult[url] = true
        if let p = endpoints.first, norm(url) == norm(p) { primaryRetryAtMs = 0 }
    }

    public func onFailure(_ url: String, now: Int64? = nil) {
        let now = now ?? clock()
        lastResult[url] = false
        if let w = winner, norm(w) == norm(url) { winner = nil }
        if let p = endpoints.first, norm(url) == norm(p) { primaryRetryAtMs = now + primaryRetryMs }
    }

    /// Walk the probe order; first ok wins. nil = all dead.
    public func resolve(now: Int64? = nil, probe: (String) async -> Bool) async -> String? {
        for e in probeOrder(now: now) {
            if await probe(e) {
                onSuccess(e)
                return winner
            }
            onFailure(e)
        }
        return nil
    }

    /// Fresh winner without unnecessary network; all-dead restores the previous winner.
    public func ensure(force: Bool = false, probe: (String) async -> Bool) async -> String? {
        if endpoints.isEmpty { return nil }
        let now = clock()
        if !force, winner != nil, !needsProbe(now: now) { return winner }
        let prev = winner
        let r = await resolve(now: now, probe: probe)
        if r == nil, let prev {
            winner = prev
            winnerAtMs = clock()
        }
        return winner
    }

    public func reportNetworkFailure(_ url: String) { onFailure(url) }

    public func describe() -> String {
        guard let w = winner else { return "no winner · \(endpoints.count) endpoints" }
        let h = Failover.host(w)
        guard let p = endpoints.first else { return h }
        return norm(w) == norm(p) ? h : "\(h) (primary \(Failover.host(p)) down)"
    }

    public static func host(_ url: String) -> String {
        let after = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
        let h = after.split(separator: "/").first.map(String.init) ?? ""
        return h.isEmpty ? url : h
    }
}
