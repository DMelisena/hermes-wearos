import Testing
@testable import HermesCore

// Cases mirror app/src/test (ProfileLogicTest, GatewayModelTest, FailoverTest, …) so the Swift
// port answers exactly like the Kotlin original on the same inputs.

@Suite struct ProfileLogicTests {
    @Test func swapProfile() {
        #expect(ProfileLogic.swapProfile("http://host:8642", "wear") == "http://host:8642/p/wear")
        #expect(ProfileLogic.swapProfile("http://host:8642/", "wear") == "http://host:8642/p/wear")
        #expect(ProfileLogic.swapProfile("http://h/p/wear", "research") == "http://h/p/research")
        #expect(ProfileLogic.swapProfile("http://h/p/wear/v1", "default") == "http://h/p/default/v1")
        #expect(ProfileLogic.swapProfile("http://h:1/p/wear", "wear") == "http://h:1/p/wear")
        #expect(ProfileLogic.swapProfile("", "wear") == nil)
        #expect(ProfileLogic.swapProfile("not a url", "wear") == nil)
        #expect(ProfileLogic.swapProfile("http://h/p/wear", "") == nil)
        #expect(ProfileLogic.swapProfile("http://h/p/wear", "Bad Name") == nil)
        #expect(ProfileLogic.swapProfile("http://h/p/wear", "../etc") == nil)
        #expect(ProfileLogic.swapProfile("http://h/p/wear", String(repeating: "a", count: 41)) == nil)
    }

    @Test func currentProfile() {
        #expect(ProfileLogic.currentProfile("http://h:8642/p/wear") == "wear")
        #expect(ProfileLogic.currentProfile("http://h:8642/p/default/") == "default")
        #expect(ProfileLogic.currentProfile("http://h:8642/p/wear/v1") == "wear")
        #expect(ProfileLogic.currentProfile("http://h:8642") == "")
        #expect(ProfileLogic.currentProfile("garbage") == "")
    }

    @Test func sessionsAndLabels() {
        #expect(ProfileLogic.sessionPrefix("wear") == "wear-watch-")
        #expect(ProfileLogic.sessionPrefix("") == "wear-watch-")
        #expect(ProfileLogic.newSessionId("default").hasPrefix("default-watch-"))
        #expect(ProfileLogic.newSessionId("wear", nowMs: 36) == "wear-watch-10")
        #expect(ProfileLogic.isWatchSession("wear-watch-mvma9on0"))
        #expect(ProfileLogic.isWatchSession("redridge-treasurer-watch-x1"))
        #expect(ProfileLogic.isWatchSession("wear-watch"))
        #expect(!ProfileLogic.isWatchSession("0f2a9c1e-4b7d-4c3f"))
        #expect(!ProfileLogic.isWatchSession("watchkit"))
        #expect(!ProfileLogic.isWatchSession(""))
        #expect(ProfileLogic.shortLabel("redridge-treasurer") == "redridge")
        #expect(ProfileLogic.chipLabel("default") == "💻 computer")
        #expect(ProfileLogic.chipLabel("") == "")
        #expect(ProfileLogic.displayAgents([], current: "wear") == ["wear", "default"])
        #expect(ProfileLogic.displayAgents(["default", "wear", "research"], current: "newbie") == ["default", "wear", "research", "newbie"])
        #expect(ProfileLogic.isValidProfile("bot.v2"))
        #expect(!ProfileLogic.isValidProfile("-lead"))
        #expect(!ProfileLogic.isValidProfile("slash/es"))
    }
}

@Suite struct GatewayModelTests {
    @Test func normalizeAndBase() {
        #expect(GatewayModel.normalizeEndpoint(" http://h:8642/p/wear/ ") == "http://h:8642")
        #expect(GatewayModel.normalizeEndpoint("http://h:8642/") == "http://h:8642")
        #expect(GatewayModel.apiBase("http://h:8642/", profile: "wear") == "http://h:8642/p/wear")
        #expect(GatewayModel.apiBase("http://h:8642", profile: "bad name") == "http://h:8642")
    }

    @Test func hostIdAndDerived() {
        #expect(GatewayModel.hostId("http://vps.example.com:8642") == "vps-example-com")
        #expect(GatewayModel.hostId("http://192.168.1.50:8642/p/wear") == "192-168-1-50")
        #expect(GatewayModel.derivedWatchkit("http://vps.example.com:8642/p/wear") == "http://vps.example.com:8651")
        #expect(GatewayModel.derivedWatchkit("garbage") == "")
    }

    @Test func keysResolveAgentThenGateway() {
        let g = Gateway(id: "g", label: "g", apiEndpoints: ["http://h"], watchkitEndpoints: [],
                        token: " wear-key ", agentKeys: ["research": "r-key", "blank": "  "])
        #expect(GatewayModel.tokenFor(g, agent: "research") == "r-key")
        #expect(GatewayModel.tokenFor(g, agent: "blank") == "wear-key")
        #expect(GatewayModel.tokenFor(nil, agent: "x", mirrorToken: "m") == "m")
    }

    @Test func upsertRoundTrip() throws {
        let seeded = [GatewayModel.seed(token: "t")]
        let added = try GatewayModel.upsert(seeded, Gateway(id: "", label: " ", apiEndpoints: ["http://vps.x:8642/p/wear", "http://vps.x:8642", ""], watchkitEndpoints: []))
        #expect(added.count == 2)
        #expect(added[1].id == "vps-x")
        #expect(added[1].label == "vps-x")
        #expect(added[1].apiEndpoints == ["http://vps.x:8642"])
        #expect(throws: GatewayModel.InvalidGateway.self) { try GatewayModel.upsert(seeded, Gateway(id: "x", label: "x", apiEndpoints: [" "], watchkitEndpoints: [])) }
        #expect(GatewayModel.decode(GatewayModel.encode(added)) == added)
        #expect(GatewayModel.decode("garbage").isEmpty)
        #expect(GatewayModel.decode(#"[{"id":"old","apiEndpoints":["http://a"]}]"#).first?.token == "")
        #expect(GatewayModel.selectedAfterRemove("hermes", list: added, removedId: "hermes") == "vps-x")
    }
}

final class FakeClock: @unchecked Sendable {
    var now: Int64 = 1_000
    func callAsFunction() -> Int64 { now }
}

@Suite struct FailoverTests {
    @Test func fallbackWinsThenPrimaryRetriesAfterBackoff() async {
        let clock = FakeClock()
        let f = Failover(endpoints: ["http://tail", "http://lan"], clock: { clock() })
        var up: Set<String> = ["http://lan"]
        var probes: [String] = []
        let probe: (String) async -> Bool = { probes.append($0); return up.contains($0) }

        #expect(await f.ensure(probe: probe) == "http://lan")
        #expect(probes == ["http://tail", "http://lan"])
        #expect(f.describe() == "lan (primary tail down)")

        probes = []
        clock.now += 1_000
        #expect(await f.ensure(probe: probe) == "http://lan")
        #expect(probes.isEmpty) // sticky inside the backoff window

        clock.now += Failover.defaultPrimaryRetryMs
        up.insert("http://tail")
        #expect(await f.ensure(probe: probe) == "http://tail")
        #expect(probes == ["http://tail"])
    }

    @Test func allDeadKeepsPreviousWinner() async {
        let clock = FakeClock()
        let f = Failover(endpoints: ["http://a", "http://b"], clock: { clock() })
        _ = await f.ensure { $0 == "http://a" }
        #expect(await f.ensure(force: true) { _ in false } == "http://a")
        #expect(f.lastResult["http://b"] == false)
    }

    @Test func networkFailureDethrones() async {
        let f = Failover(endpoints: ["http://a", "http://b"])
        _ = await f.ensure { _ in true }
        f.reportNetworkFailure("http://a/")
        #expect(f.winner == nil)
        #expect(f.effective() == "http://a")
        #expect(await f.resolve { $0 == "http://b" } == "http://b")
    }
}

@Suite struct SessionsTests {
    let wire = #"{"object":"list","data":[{"id":"old","title":"Old","last_active":100.5,"message_count":3},{"id":"new","title":"New","last_active":200,"message_count":"7"},{"title":"no id"}]}"#

    @Test func parseSortsNewestFirst() throws {
        let rows = try GatewaySessions.parse(wire)
        #expect(rows.map(\.id) == ["new", "old"])
        #expect(rows[0].messages == 7)
        #expect(rows[1].lastActiveMs == 100_500)
    }

    @Test func mergePrefersTaggedAndCaps() throws {
        let a = try GatewaySessions.parseProfiled(wire, profile: "wear")
        let b = try GatewaySessions.parse(wire)
        let merged = GatewaySessions.merge(b + a)
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.profile == "wear" })
        #expect(try GatewaySessions.parse(GatewaySessions.encode(merged)) == merged)
        let many = (0..<50).map { GatewaySessions.Info(id: "s\($0)", title: "", lastActiveMs: Int64($0), messages: 0) }
        #expect(GatewaySessions.merge(many).count == GatewaySessions.maxRows)
        #expect(try GatewaySessions.parseAgents(#"{"agents":["wear"," wear ","",  "default"]}"#) == ["wear", "default"])
    }
}

@Suite struct HistoryTests {
    @Test func parseMapsRolesAndDropsNoise() throws {
        let t = #"{"messages":[{"role":"user","content":"hi"},{"role":"tool","content":"x"},{"role":"assistant","content":"  yo "},{"role":"summary","content":"s"},{"role":"user","content":"[SYSTEM: Background process 1"},{"role":"assistant","content":""}]}"#
        let rows = try SessionHistory.parse(t)
        #expect(rows.map(\.text) == ["hi", "yo", "🗂 summary · s"])
        #expect(rows.map(\.role) == [.User, .Hermes, .Hermes])
        #expect(try SessionHistory.parse(t, cap: 1).map(\.text) == ["🗂 summary · s"])
    }

    @Test func catchUpAppendsOnlyTheNewTail() {
        func m(_ r: ChatMessage.Role, _ t: String) -> ChatMessage { ChatMessage(id: 0, role: r, text: t) }
        let gw = [m(.User, "q"), m(.Hermes, "a"), m(.User, "q2"), m(.Hermes, "a2")]
        let local = [m(.System, "history"), m(.User, "q"), m(.Hermes, "a")]
        #expect(SessionHistory.catchUpPlan(gateway: gw, local: local) == Array(gw[2...]))
        #expect(SessionHistory.catchUpPlan(gateway: gw, local: gw) == nil)
        #expect(SessionHistory.catchUpPlan(gateway: gw, local: [m(.User, "other")]) == nil)
        #expect(SessionHistory.catchUpPlan(gateway: gw, local: []) == nil)
        #expect(SessionHistory.profileProbes("") == ["default"])
        #expect(SessionHistory.profileProbes("wear") == ["wear", "default"])
        #expect(SessionHistory.shouldBackfill(sessionId: "s", localTranscriptSize: 0))
        #expect(!SessionHistory.shouldBackfill(sessionId: "s", localTranscriptSize: 1))
    }
}

@Suite struct RunEventTests {
    @Test func decodesWireEvents() {
        #expect(RunEvent.parse(runId: "r", data: #"{"event":"message.delta","delta":"Hel"}"#) == .delta("Hel"))
        #expect(RunEvent.parse(runId: "r", data: #"{"event":"message.interim","text":"x","already_streamed":true}"#) == .ignored)
        #expect(RunEvent.parse(runId: "r", data: #"{"event":"message.interim","text":"x","already_streamed":"true"}"#) == .interim("x"))
        #expect(RunEvent.parse(runId: "r", data: #"{"event":"tool.started","tool":"web"}"#) == .toolStarted("web"))
        #expect(RunEvent.parse(runId: "r", data: #"{"event":"run.completed"}"#) == .completed(nil))
        #expect(RunEvent.parse(runId: "r", data: #"{"event":"run.failed","turn_exit_reason":"boom"}"#) == .failed("boom"))
        #expect(RunEvent.parse(runId: "r", data: "not json") == .ignored)
        let ap = RunEvent.parse(runId: "r", data: #"{"event":"approval.request","command":"rm -rf x","request_id":"q1","choices":[{"id":"once"},{"id":"deny"}]}"#)
        #expect(ap == .approval(ApprovalInfo(runId: "r", requestId: "q1", question: "rm -rf x", choices: ["once", "deny"])))
    }

    @Test func sseFraming() {
        var p = SSEParser()
        #expect(p.feed("id: 1") == nil)
        #expect(p.feed(": keepalive") == nil)
        #expect(p.feed("data: {\"a\":1}\r") == nil)
        #expect(p.feed("") == "{\"a\":1}")
        #expect(p.feed("") == nil)
        #expect(p.feed("data:x") == nil)
        #expect(p.finish() == "x")
    }
}

@Suite struct MarkdownTests {
    @Test func blocks() {
        let md = """
        # Title ##
        para line
        - item
          - nested
        2) two
        > quoted
        ```swift
        let x = 1
        ```
        ```mermaid
        graph TD
        ```
        ![chart](/tmp/c.png)
        MEDIA:/srv/a/aurora.PNG
        | k | v |
        |---|---|
        | a | 1 |
        ---
        """
        #expect(WatchMarkdown.parse(md) == [
            .heading(level: 1, text: "Title"), .paragraph("para line"), .bullet(text: "item", indent: 0),
            .bullet(text: "nested", indent: 1), .numbered(n: 2, text: "two"), .quote("quoted"),
            .code(lang: "swift", code: "let x = 1"), .mermaid("graph TD"), .image(alt: "chart", target: "/tmp/c.png"),
            .image(alt: "aurora.PNG", target: "/srv/a/aurora.PNG"), .table(["· k: a", "· v: 1"]), .hr,
        ])
        // Stream-safe: an unclosed fence keeps everything after it.
        #expect(WatchMarkdown.parse("```\nabc") == [.code(lang: "", code: "abc")])
        #expect(WatchMarkdown.speakable("**Hi** `x`\n![a](/b.png)") == "Hi x")
    }
}

@Suite struct SearchAndCatalogTests {
    @Test func mergeRanksTitleThenHits() {
        let chats = [ChatMeta(id: "c1", sessionTitle: "wear-watch-1", label: "Groceries", updatedAt: 5),
                     ChatMeta(id: "c2", sessionTitle: "wear-watch-2", label: "", updatedAt: 9)]
        let local = SessionSearch.localHits(chats, "milk") { id in
            id == "c2" ? [ChatMessage(id: 1, role: .User, text: "buy milk today")] : []
        }
        #expect(local.map(\.id) == ["c2"])
        #expect(local[0].snippet == "buy milk today")
        let gw = [SessionHit(id: "g", title: "Milk run", profile: "default", snippet: "", source: .gateway, hits: 1, titleMatch: true)]
        #expect(SessionSearch.merge(local: local, gateway: gw).map(\.id) == ["g", "c2"])
    }

    @Test func catalogKeepsAuthedProvidersCurrentFirst() throws {
        let root = try JSON.object(#"{"model":"m1","provider":"b","providers":[{"slug":"a","authenticated":true,"models":["x","x",""]},{"slug":"b","name":"B","authenticated":true,"is_current":true,"models":["m1"]},{"slug":"c","authenticated":false,"models":["z"]},{"slug":"d","authenticated":true,"models":[]}]}"#)
        let cat = ModelCatalog.parse(root)
        #expect(cat.groups.map(\.provider) == ["b", "a"])
        #expect(cat.allModels() == ["m1", "x"])
        #expect(ModelCatalog.shortName("openrouter/anthropic/claude") == "claude")
    }

    @Test func deepLink() {
        #expect(NotificationDeepLink.plan(currentProfile: "wear", chatProfile: "research", chatKnown: true) == .switchThenOpen("research"))
        #expect(NotificationDeepLink.plan(currentProfile: "wear", chatProfile: "wear", chatKnown: true) == .open)
        #expect(NotificationDeepLink.plan(currentProfile: "wear", chatProfile: "x", chatKnown: false) == .open)
        #expect(SessionManage.chatLabel("") == "fork")
        #expect(SessionManage.chatLabel("Plan (fork)") == "Plan (fork)")
    }
}

final class FakeProber: Prober, @unchecked Sendable {
    var up: Set<String>
    init(up: Set<String>) { self.up = up }
    func ok(_ url: String) async -> Bool { up.contains(url) }
}

@Suite struct ResolverTests {
    @Test func profiledHealthThenAdvance() async {
        let gw = Gateway(id: "g", label: "g", apiEndpoints: ["http://tail:8642", "http://lan:8642"],
                         watchkitEndpoints: ["http://tail:8651", "http://lan:8651"])
        let prober = FakeProber(up: ["http://lan:8642/p/wear/v1/health", "http://tail:8642/health", "http://lan:8651/health"])
        let r = EndpointResolver(prober: prober)
        let s = await r.ensure(gw, profile: "wear")
        #expect(s.apiWinner == "http://tail:8642") // bare /health counts as alive
        #expect(s.watchkitWinner == "http://lan:8651")
        // Still answering → nothing better to advance to (caller keeps its base and retries).
        #expect(await r.advance(from: "http://tail:8642/p/wear", gateway: gw, profile: "wear") == nil)
        prober.up.remove("http://tail:8642/health")
        #expect(await r.advance(from: "http://tail:8642/p/wear", gateway: gw, profile: "wear") == "http://lan:8642/p/wear")
    }
}
