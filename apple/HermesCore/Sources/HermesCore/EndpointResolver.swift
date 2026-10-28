import Foundation

/// Health probe — true on 2xx. Injectable so the resolver stays testable.
public protocol Prober: Sendable {
    func ok(_ url: String) async -> Bool
}

/// Default prober: 2.5 s hard leash — a dead tailnet URL must fail FAST (SPEC §11).
public struct HTTPProber: Prober {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2.5
        c.timeoutIntervalForResource = 2.8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    public init() {}

    public func ok(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        do {
            let (_, resp) = try await HTTPProber.session.data(from: u)
            return ((resp as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } ?? false
        } catch {
            return false
        }
    }
}

/// Endpoint failover for the SELECTED gateway (port of `net/EndpointResolver.kt`). The api probe
/// is `{endpoint}/p/{agent}/v1/health`, then bare `{endpoint}/health`; watchkit is `{url}/health`.
public actor EndpointResolver {
    public struct Status: Equatable, Sendable {
        public var gatewayId = ""
        public var apiWinner = ""
        public var watchkitWinner = ""
        public var apiResults: [String: Bool] = [:]
        public var watchkitResults: [String: Bool] = [:]
        public init() {}
    }

    private let prober: Prober
    private var apiF: Failover?
    private var wkF: Failover?
    private var boundId = ""
    public private(set) var status = Status()

    public init(prober: Prober = HTTPProber()) { self.prober = prober }

    public func bind(_ gw: Gateway, force: Bool = false) {
        if !force, boundId == gw.id, apiF != nil, apiF?.endpoints == gw.apiEndpoints { return }
        apiF = Failover(endpoints: gw.apiEndpoints)
        wkF = Failover(endpoints: gw.watchkitEndpoints)
        boundId = gw.id
        status = Status()
        status.gatewayId = gw.id
        status.apiWinner = gw.primaryApi
        status.watchkitWinner = gw.primaryWatchkit
    }

    private func probeApi(_ endpoint: String, profile: String) async -> Bool {
        let base = ProfileLogic.trimBase(endpoint)
        if ProfileLogic.isValidProfile(profile), await prober.ok("\(base)/p/\(profile)/v1/health") { return true }
        return await prober.ok("\(base)/health")
    }

    /// Pick api + watchkit endpoints; probes only when stale/forced.
    public func ensure(_ gw: Gateway, profile: String, force: Bool = false) async -> Status {
        bind(gw)
        guard let apiF, let wkF else { return status }
        let prober = self.prober
        _ = await apiF.ensure(force: force) { await self.probeApi($0, profile: profile) }
        _ = await wkF.ensure(force: force) { await prober.ok("\($0)/health") }
        status.apiWinner = apiF.effective()
        status.watchkitWinner = wkF.effective()
        status.apiResults = apiF.lastResult
        status.watchkitResults = wkF.lastResult
        return status
    }

    /// A request to `usedBaseUrl` died: dethrone, re-probe once, return the NEW profiled base or nil.
    public func advance(from usedBaseUrl: String, gateway gw: Gateway, profile: String) async -> String? {
        bind(gw)
        guard let f = apiF else { return nil }
        let used = GatewayModel.normalizeEndpoint(usedBaseUrl)
        f.reportNetworkFailure(used)
        let next = await f.resolve { await self.probeApi($0, profile: profile) } ?? f.effective()
        status.apiWinner = f.effective()
        status.apiResults = f.lastResult
        guard !next.isEmpty, next != used else { return nil }
        return GatewayModel.apiBase(next, profile: profile)
    }
}
