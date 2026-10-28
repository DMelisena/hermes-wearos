import Foundation
import HermesCore

/// Multi-chat engine (port of `domain/ChatSession.kt`, SPEC §1, §3): each watch chat = one
/// Hermes session; durable idempotency per ask; SSE while foreground with a status poller as the
/// approval watchdog and never-lose-the-answer net (terminal snapshots carry `output`).
@MainActor
final class ChatSession: ObservableObject {
    struct UIState {
        var messages: [ChatMessage] = []
        var live = ""
        var status = ""
        var approval: ApprovalInfo?
        var busy = false
        var gen: Int64 = 0
        var activeChatId = ""
        var activeChatLabel = ""
    }

    struct SessionsMeta {
        var stale = false
        var fetchedAt: Date?
        var error = ""
    }

    struct ModelState {
        var loading = false
        var error = ""
        var catalog: ModelCatalog.Catalog?
        var picked = ""
    }

    @Published private(set) var state = UIState()
    @Published private(set) var gatewaySessions: [GatewaySessions.Info] = []
    @Published private(set) var archivedSessions: [GatewaySessions.Info] = []
    @Published private(set) var sessionsMeta = SessionsMeta()
    @Published private(set) var searchHits: [SessionHit] = []
    @Published private(set) var modelState = ModelState()
    @Published private(set) var capabilities: [String: Bool] = [:]
    /// One-line transient feedback (the Android Toasts).
    @Published var toast: String?

    var isForeground = true
    let settings: AppSettings
    let store: ChatStore
    private let speaker = Speaker()

    private var askTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var messageLog: [ChatMessage] = []
    private var idCounter: Int64 = 0
    private var currentRunId = ""
    private var lastFinishedRun: String?
    private var lastApprovalNotified: String?
    private var stoppedRunId = ""
    private var watchPollRun = ""
    private var activeId = ""
    private var catchUpAt: [String: Date] = [:]
    private var catalogCache: (base: String, at: Date, catalog: ModelCatalog.Catalog)?
    private let historyTimeout: Double = 10

    init(settings: AppSettings, store: ChatStore) {
        self.settings = settings
        self.store = store
    }

    private func api(_ base: String? = nil) -> HermesAPI { settings.api(base: base) }

    private func nextId() -> Int64 { idCounter += 1; return idCounter }

    private func add(_ role: ChatMessage.Role, _ text: String) {
        messageLog.append(ChatMessage(id: nextId(), role: role, text: text))
        state.messages = messageLog
    }

    private func saveActive() { if !activeId.isEmpty { store.saveTranscript(activeId, messageLog) } }

    /// A 401 on a multiplexed gateway usually means THIS agent has no key on the box (SPEC §12.2).
    private func explain(_ e: Error) -> String {
        if (e as? ApiError)?.code == 401 { return "no key for \(settings.profile) — Settings ▸ Gateways ▸ Agent keys" }
        return (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
    }

    // MARK: lifecycle

    /// App start: probe endpoints, reopen the remembered agent's chat, settle a run in flight.
    func resume() {
        Task {
            await settings.ensureEndpoints()
            let agent = settings.profile
            if let meta = store.get(store.activeId), meta.profile == agent {
                enterChat(meta, store.loadTranscript(meta.id))
            } else if let mine = store.chats.filter({ $0.profile == agent }).max(by: { $0.updatedAt < $1.updatedAt }) {
                store.setActive(mine.id)
                enterChat(mine, store.loadTranscript(mine.id))
            } else {
                let d = store.draft(label: nil, profile: agent)
                store.addActive(d)
                enterChat(d, [])
            }
            await resumeRun()
            catchUpActive()
            loadCapabilities()
        }
    }

    /// Back on the wrist: the stream died with the app suspended — re-attach or settle.
    func onForeground() {
        isForeground = true
        Notifications.cancelChat(activeId)
        guard !activeId.isEmpty else { return }
        store.update(activeId) { $0.pendingAttention = false }
        if state.busy || !(store.get(activeId)?.lastRunId.isEmpty ?? true) {
            watchPollRun = ""
            Task { await resumeRun() }
        } else {
            catchUpActive()
        }
    }

    private func enterChat(_ meta: ChatMeta, _ transcript: [ChatMessage], cancelAsk: Bool = true) {
        streamTask?.cancel()
        pollTask?.cancel()
        if cancelAsk { askTask?.cancel() }
        activeId = meta.id
        messageLog = transcript
        idCounter = transcript.map(\.id).max() ?? 0
        currentRunId = ""
        lastFinishedRun = nil
        lastApprovalNotified = nil
        watchPollRun = ""
        Notifications.cancelChat(meta.id)
        store.update(meta.id) { $0.pendingAttention = false }
        modelState = ModelState(picked: meta.model)
        adoptSessionModel(meta)
        state = UIState(messages: messageLog, gen: state.gen + 1, activeChatId: meta.id, activeChatLabel: meta.label)
    }

    private func resumeRun() async {
        guard let meta = store.get(activeId), !meta.lastRunId.isEmpty else { return }
        let runId = meta.lastRunId
        currentRunId = runId
        let a = api()
        guard let snap = try? await a.runStatus(runId) else { return } // offline: reads still work
        switch snap.status {
        case "completed": finishWith(snap.output ?? "")
        case "failed": finishWith("⚠️ run failed", error: true)
        case "cancelled": finishWith("(cancelled)")
        default:
            state.busy = true
            state.status = "still working…"
            openEventStream(a, runId)
        }
    }

    // MARK: chats

    func openChat(_ id: String) {
        guard id != activeId, let meta = store.get(id) else { return }
        saveActive()
        store.setActive(id)
        enterChat(meta, store.loadTranscript(id))
        Task { await resumeRun(); catchUpActive() }
    }

    @discardableResult
    func newChat(label: String? = nil) -> ChatMeta {
        let d = store.draft(label: label, profile: settings.profile)
        saveActive()
        store.addActive(d)
        enterChat(d, [])
        return d
    }

    func renameChat(_ id: String, _ label: String) {
        store.rename(id, label)
        if id == activeId { state.activeChatLabel = label.trimmingCharacters(in: .whitespaces) }
    }

    func deleteChat(_ id: String) {
        guard store.get(id) != nil else { return }
        if store.activeId == id {
            if let next = store.chats.filter({ $0.id != id }).max(by: { $0.updatedAt < $1.updatedAt }) {
                store.setActive(next.id)
                store.delete(id)
                enterChat(next, store.loadTranscript(next.id))
                Task { await resumeRun() }
            } else {
                newChat()
                store.delete(id)
            }
        } else {
            store.delete(id)
        }
    }

    /// Deep link from a notification: a chat on another agent switches first.
    func openFromNotification(_ chatId: String) {
        let meta = store.get(chatId)
        switch NotificationDeepLink.plan(currentProfile: settings.profile, chatProfile: meta?.profile ?? "", chatKnown: meta != nil) {
        case .open: openChat(chatId)
        case .switchThenOpen(let agent): switchAgent(agent) { [weak self] ok in if ok { self?.openChat(chatId) } }
        }
    }

    // MARK: asking

    /// Composer entry: the watch-local slash verbs, everything else goes to the gateway as typed.
    func submit(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func arg(_ verb: String) -> String? {
            guard t.lowercased().hasPrefix(verb + " ") else { return nil }
            return String(t.dropFirst(verb.count + 1))
        }
        if let a = arg("/btw") { sideAsk(a) }
        else if let a = arg("/steer") { steer(a) }
        else if t == "/fork" { forkActive() }
        else if t == "/new" { newChat() }
        else if t == "/stop" { stopActiveRun() }
        else if state.busy { steer(t) }
        else { ask(t) }
    }

    func ask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !state.busy else { return }
        stoppedRunId = ""
        add(.User, t)
        state.busy = true
        state.live = ""
        state.status = "sending…"
        askTask?.cancel()
        askTask = Task {
            do {
                if activeId.isEmpty || store.get(activeId) == nil {
                    let d = store.draft(label: nil, profile: settings.profile)
                    store.addActive(d)
                    enterChat(d, messageLog, cancelAsk: false)
                    state.busy = true
                    state.status = "sending…"
                }
                await settings.ensureEndpoints()
                let a = api()
                guard let meta = store.get(activeId) else { return }
                let model = meta.model.isEmpty ? HermesAPI.virtualModel : meta.model
                let idem = UUID().uuidString
                var used = a
                let accepted: HermesAPI.RunAccepted
                do {
                    accepted = try await a.submitRun(input: t, sessionId: meta.sessionTitle, idempotencyKey: idem, model: model)
                } catch {
                    if error is CancellationError { throw error }
                    // Endpoint failover (SPEC §11): the Idempotency-Key makes the retry a replay.
                    let next = await settings.advance(from: a.baseUrl)
                    if next == nil { try await Task.sleep(nanoseconds: 1_500_000_000) }
                    used = api(next)
                    accepted = try await used.submitRun(input: t, sessionId: meta.sessionTitle, idempotencyKey: idem, model: model)
                }
                try Task.checkCancellation()
                store.update(activeId) { $0.lastRunId = accepted.runId; $0.updatedAt = nowMs() }
                currentRunId = accepted.runId
                state.status = "thinking…"
                openEventStream(used, accepted.runId)
            } catch is CancellationError {
            } catch {
                finishWith("⚠️ \(explain(error))", error: true)
            }
        }
    }

    private func openEventStream(_ a: HermesAPI, _ runId: String) {
        streamTask?.cancel()
        streamTask = Task {
            do {
                for try await data in a.events(runId) { handle(runId, data) }
            } catch {}
        }
        // APPROVAL WATCHDOG: a run parked on approval can keep the SSE open and SILENT.
        watchRun(a, runId)
    }

    private func watchRun(_ a: HermesAPI, _ runId: String) {
        guard watchPollRun != runId else { return }
        watchPollRun = runId
        pollTask?.cancel()
        pollTask = Task { await pollUntilTerminal(a, runId) }
    }

    private func handle(_ runId: String, _ data: String) {
        guard runId == currentRunId, runId != stoppedRunId else { return }
        switch RunEvent.parse(runId: runId, data: data) {
        case .delta(let d): state.live += d; state.status = ""
        case .interim(let t): state.live += t
        case .toolStarted(let tool): state.status = "🔧 \(tool)…"
        case .toolCompleted: state.status = ""
        case .approval(let info): onApproval(info)
        case .completed(let out): finishWith(out ?? state.live)
        case .failed(let why): finishWith("⚠️ \(why)", error: true)
        case .cancelled: finishWith("(cancelled)")
        case .ignored: break
        }
    }

    private func pollUntilTerminal(_ a: HermesAPI, _ runId: String) async {
        while runId == currentRunId, !Task.isCancelled {
            if let snap = try? await a.runStatus(runId), runId == currentRunId, runId != stoppedRunId {
                switch snap.status {
                case "completed": return finishWith(snap.output ?? state.live)
                case "failed": return finishWith("⚠️ run failed", error: true)
                case "cancelled": return finishWith("(cancelled)")
                case "waiting_for_approval": if let ap = snap.approval { onApproval(ap) }
                default: break
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: approvals

    private func onApproval(_ info: ApprovalInfo) {
        state.approval = info
        guard !isForeground else { return }
        let key = info.requestId ?? info.runId
        guard lastApprovalNotified != key else { return }
        lastApprovalNotified = key
        store.update(activeId) { $0.pendingAttention = true }
        Notifications.approval(chatId: activeId, info: info)
    }

    func respondApproval(_ choice: String) {
        guard let info = state.approval else { return }
        state.approval = nil
        state.status = "running…"
        lastApprovalNotified = nil
        Notifications.cancelApproval(info.runId)
        Task {
            do { try await api().respondApproval(runId: info.runId, choice: choice, requestId: info.requestId) }
            catch { finishWith("⚠️ approval failed: \(explain(error))", error: true) }
        }
    }

    /// Approve/Deny from a notification: first choice = affirmative, last = denial.
    func respondApprovalFromNotification(runId: String, approve: Bool) async {
        for _ in 0..<24 where state.approval?.runId != runId { try? await Task.sleep(nanoseconds: 250_000_000) }
        if let info = state.approval, info.runId == runId {
            respondApproval(approve ? info.choices.first! : info.choices.last!)
            return
        }
        let ap = try? await api().runStatus(runId).approval
        let names = ap?.choices ?? ["approve", "deny"]
        try? await api().respondApproval(runId: runId, choice: approve ? names.first! : names.last!, requestId: ap?.requestId)
    }

    // MARK: run control

    /// STOP: detach now, settle the partial answer, best-effort server cancel.
    func stopActiveRun() {
        guard state.busy else { return }
        let runId = currentRunId
        let live = state.live
        stoppedRunId = runId
        streamTask?.cancel()
        pollTask?.cancel()
        askTask?.cancel()
        if !runId.isEmpty {
            lastFinishedRun = runId
            let a = api()
            Task { _ = try? await a.stopRun(runId) }
        }
        currentRunId = ""
        speaker.stop()
        if !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.Hermes, live) }
        add(.System, "— stopped —")
        state.live = ""
        state.status = ""
        state.busy = false
        state.approval = nil
        store.update(activeId) { $0.lastRunId = ""; $0.updatedAt = nowMs() }
        saveActive()
    }

    /// `/steer`: guidance into the run in flight; nothing in flight → a plain ask.
    func steer(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let runId = currentRunId
        guard !runId.isEmpty, runId != lastFinishedRun, state.busy else { return ask(t) }
        Task {
            do {
                _ = try await api().steerRun(runId, text: t)
                add(.User, "⟳ steer: \(t)")
                saveActive()
            } catch {
                if state.busy { add(.System, "— steer refused: \(explain(error)) —") } else { ask(t) }
            }
        }
    }

    /// `/fork`: branch the gateway session and keep typing HERE.
    func forkActive() {
        Task {
            guard let old = store.get(activeId)?.sessionTitle, !old.isEmpty else {
                return add(.System, "— /fork: this chat has no gateway session yet —")
            }
            guard let forked = try? await api().forkSession(old) else {
                return add(.System, "— /fork failed (offline or no key) —")
            }
            store.update(activeId) { $0.sessionTitle = forked; $0.updatedAt = nowMs() }
            add(.System, "— branched → \(forked.prefix(18)) · parent untouched, history carried —")
        }
    }

    /// `/btw <aside>`: the side conversation gets its OWN chat on a forked session.
    func sideAsk(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            let old = store.get(activeId)?.sessionTitle ?? ""
            let forked = old.isEmpty ? nil : try? await api().forkSession(old)
            let label = "btw: \(t.prefix(24))"
            let d = forked.map { store.draft(adopting: $0, label: label, profile: settings.profile) }
                ?? store.draft(label: label, profile: settings.profile)
            saveActive()
            store.addActive(d)
            enterChat(d, [])
            add(.System, forked != nil ? "— side branch · sees the parent's context —" : "— /btw without a fork (offline or no session yet) —")
            ask(t)
        }
    }

    /// FORK ON EDIT (SPEC §12.5): roll back to before the edited turn, fork, ask fresh on the branch.
    func editAndResend(_ messageId: Int64, _ newText: String) {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard let idx = messageLog.firstIndex(where: { $0.id == messageId }), messageLog[idx].role == .User else { return ask(t) }
        streamTask?.cancel()
        pollTask?.cancel()
        askTask?.cancel()
        let kept = Array(messageLog[..<idx])
        Task {
            let old = store.get(activeId)?.sessionTitle ?? ""
            let forked = old.isEmpty ? nil : try? await api().forkSession(old)
            if let forked { store.update(activeId) { $0.sessionTitle = forked; $0.updatedAt = nowMs() } }
            messageLog = kept
            currentRunId = ""
            state.messages = kept
            state.live = ""
            state.status = ""
            state.busy = false
            state.approval = nil
            add(.System, forked != nil ? "— edited · branched (the superseded answer stays in context) —"
                                       : "— edited · fork unavailable, appended instead —")
            saveActive()
            ask(t)
        }
    }

    private func finishWith(_ text: String, error: Bool = false) {
        // Exactly-once settle: SSE terminal event, poller, or resume may race.
        if !currentRunId.isEmpty, lastFinishedRun == currentRunId { return }
        lastFinishedRun = currentRunId
        streamTask?.cancel()
        pollTask?.cancel()
        if !currentRunId.isEmpty { Notifications.cancelApproval(currentRunId) }
        add(error ? .System : .Hermes, text)
        state.live = ""
        state.status = ""
        state.busy = false
        state.approval = nil
        let chatId = activeId
        store.update(chatId) { $0.lastRunId = ""; $0.updatedAt = nowMs() }
        saveActive()
        if !error, messageLog.filter({ $0.role == .Hermes }).count == 1 { enrichLabel(chatId) }
        if !error, settings.voiceOut, isForeground { speaker.speak(WatchMarkdown.speakable(text)) }
        if !chatId.isEmpty, !isForeground {
            store.update(chatId) { $0.pendingAttention = true }
            Notifications.settle(chatId: chatId, label: store.get(chatId)?.displayLabel ?? "", text: text, error: error)
        }
    }

    /// First settled answer: pull the gateway's session title into an empty label.
    private func enrichLabel(_ chatId: String) {
        Task {
            guard let meta = store.get(chatId), meta.label.isEmpty,
                  let s = try? await api().listSessions().first(where: { $0.id == meta.sessionTitle }), !s.title.isEmpty else { return }
            store.update(chatId) { $0.label = s.title }
            if chatId == activeId { state.activeChatLabel = s.title }
        }
    }

    // MARK: agents

    func switchAgent(_ agent: String, onDone: ((Bool) -> Void)? = nil) {
        guard settings.setProfile(agent) else { toast = "bad agent name"; onDone?(false); return }
        streamTask?.cancel()
        pollTask?.cancel()
        askTask?.cancel()
        if let target = store.chats.filter({ $0.profile == agent }).max(by: { $0.updatedAt < $1.updatedAt }) {
            if target.id != activeId { saveActive() }
            store.setActive(target.id)
            enterChat(target, store.loadTranscript(target.id))
            Task { await resumeRun() }
        } else {
            newChat()
        }
        Task {
            await settings.ensureEndpoints()
            _ = await settings.refreshAgentKeys()
            refreshGatewaySessions()
            loadCapabilities()
        }
        onDone?(true)
    }

    func refreshAgents() async {
        if let list = try? await settings.watchkit.agents(), !list.isEmpty { settings.setAgentsCache(list) }
    }

    private func loadCapabilities() {
        Task { capabilities = (try? await api().capabilities()) ?? [:] }
    }

    // MARK: models (SPEC §12.7)

    func refreshModels(force: Bool = false) {
        modelState.loading = true
        modelState.error = ""
        modelState.picked = store.get(activeId)?.model ?? ""
        Task {
            let a = api()
            if !force, let c = catalogCache, c.base == a.baseUrl, Date().timeIntervalSince(c.at) < 180 {
                modelState = ModelState(catalog: c.catalog, picked: modelState.picked)
                return
            }
            do {
                let cat = try await a.modelOptions()
                catalogCache = (a.baseUrl, Date(), cat)
                modelState = ModelState(catalog: cat, picked: modelState.picked)
            } catch {
                modelState.loading = false
                modelState.error = explain(error)
            }
        }
    }

    /// Takes effect on the NEXT ask — the running turn keeps its model.
    func pickModel(_ model: String) {
        guard !activeId.isEmpty else { return }
        store.update(activeId) { $0.model = model; $0.updatedAt = nowMs() }
        modelState.picked = model
    }

    var pickedModel: String { store.get(activeId)?.model ?? "" }

    /// Un-picked chats keep the model their last turn used on the gateway.
    private func adoptSessionModel(_ meta: ChatMeta) {
        guard meta.model.isEmpty, !meta.sessionTitle.isEmpty else { return }
        Task {
            if let stamped = await api().sessionModel(meta.sessionTitle), !stamped.isEmpty, store.get(meta.id)?.model.isEmpty == true {
                store.update(meta.id) { $0.model = stamped }
                if meta.id == activeId { modelState.picked = stamped }
            }
        }
    }

    // MARK: gateway sessions

    /// Adopt gateway session `sessionId` (desktop chat → wrist); history backfills async.
    func resumeGatewaySession(_ sessionId: String, title: String = "", sourceProfile: String = "") {
        guard !sessionId.isEmpty else { return }
        if let existing = store.chats.first(where: { $0.sessionTitle == sessionId }) {
            if existing.id != activeId {
                saveActive()
                store.setActive(existing.id)
                enterChat(existing, store.loadTranscript(existing.id))
                Task { await resumeRun() }
            }
            backfillHistory(existing, localCount: messageLog.count, profileHint: sourceProfile)
            catchUpActive()
            return
        }
        saveActive()
        let meta = store.draft(adopting: sessionId, label: title.isEmpty ? nil : title, profile: settings.profile)
        store.addActive(meta)
        enterChat(meta, [])
        backfillHistory(meta, localCount: 0, profileHint: sourceProfile)
    }

    /// Open a Sessions row; a foreign-profile row swaps the agent first.
    func openSessionRow(_ row: GatewaySessions.Info) {
        if !row.profile.isEmpty, row.profile != settings.profile {
            switchAgent(row.profile) { [weak self] ok in
                if ok { self?.resumeGatewaySession(row.id, title: row.title, sourceProfile: row.profile) }
            }
        } else {
            resumeGatewaySession(row.id, title: row.title, sourceProfile: row.profile)
        }
    }

    private func fetchHistory(_ profile: String, _ sessionId: String) async -> [ChatMessage]? {
        let wk = settings.watchkit
        return await withTimeout(historyTimeout) {
            try SessionHistory.parse(try await wk.sessionMessagesJson(profile: profile, sessionId: sessionId))
        }
    }

    private func backfillHistory(_ meta: ChatMeta, localCount: Int, profileHint: String) {
        guard SessionHistory.shouldBackfill(sessionId: meta.sessionTitle, localTranscriptSize: localCount) else { return }
        Task {
            for p in SessionHistory.profileProbes(profileHint.isEmpty ? meta.profile : profileHint) {
                guard let msgs = await fetchHistory(p, meta.sessionTitle), !msgs.isEmpty else { continue }
                var stamped = [ChatMessage(id: nextId(), role: .System, text: SessionHistory.captionLine(count: msgs.count, profile: p))]
                stamped += msgs.map { ChatMessage(id: nextId(), role: $0.role, text: $0.text) }
                if activeId == meta.id {
                    messageLog = stamped + messageLog // what the user sent during the fetch stays newest
                    state.messages = messageLog
                    store.saveTranscript(meta.id, messageLog)
                } else if store.loadTranscript(meta.id).isEmpty {
                    store.saveTranscript(meta.id, stamped)
                }
                return
            }
            toast = "history unavailable — continuing live"
        }
    }

    /// Re-pull the active chat's gateway tail and append what the desktop added meanwhile.
    func catchUpActive(manual: Bool = false) {
        let chatId = activeId
        guard !chatId.isEmpty, catchUpTask == nil, !state.busy else { return }
        if !manual, let last = catchUpAt[chatId], Date().timeIntervalSince(last) < 5 { return }
        catchUpAt[chatId] = Date()
        catchUpTask = Task {
            defer { catchUpTask = nil }
            guard let meta = store.get(chatId), !meta.sessionTitle.isEmpty, !messageLog.isEmpty else {
                if manual { toast = "nothing to sync" }
                return
            }
            let snapshot = messageLog
            for p in SessionHistory.profileProbes(meta.profile) {
                guard let msgs = await fetchHistory(p, meta.sessionTitle), !msgs.isEmpty else { continue }
                guard chatId == activeId, let plan = SessionHistory.catchUpPlan(gateway: msgs, local: snapshot) else {
                    if manual { toast = "up to date" }
                    return
                }
                messageLog += plan.map { ChatMessage(id: nextId(), role: $0.role, text: $0.text) }
                state.messages = messageLog
                saveActive()
                if manual { toast = "+\(plan.count) synced" }
                return
            }
            if manual { toast = "sync unavailable" }
        }
    }

    /// Current agent via the gateway (watchkit fallback for key-less agents) + the desktop
    /// profile via watchkit; merged newest-first, capped to 30; stale cache when offline.
    func refreshGatewaySessions() {
        Task {
            let current = settings.profile
            let wk = settings.watchkit
            archivedSessions = (try? GatewaySessions.parseProfiled(try await wk.sessionsJson(profile: current, archived: true), profile: current)) ?? []
            var mine: [GatewaySessions.Info] = []
            var error = ""
            do {
                mine = try GatewaySessions.parseProfiled(try await api().sessionsJson(), profile: current)
            } catch let gatewayError {
                if let via = try? GatewaySessions.parseProfiled(try await wk.sessionsJson(profile: current), profile: current), !via.isEmpty {
                    mine = via
                } else {
                    gatewaySessions = (try? GatewaySessions.parse(settings.sessionsCache)) ?? []
                    sessionsMeta = SessionsMeta(stale: true, fetchedAt: Date(), error: explain(gatewayError))
                    error = explain(gatewayError)
                }
            }
            if !error.isEmpty { return }
            let computer = current == ProfileLogic.profileComputer ? [] :
                ((try? GatewaySessions.parseProfiled(try await wk.sessionsJson(profile: ProfileLogic.profileComputer), profile: ProfileLogic.profileComputer)) ?? [])
            let merged = GatewaySessions.merge(mine + computer)
            gatewaySessions = merged
            sessionsMeta = SessionsMeta(stale: false, fetchedAt: Date())
            settings.setSessionsCache(GatewaySessions.encode(merged))
        }
    }

    /// Long-press → fork into THIS agent's store via watchkit (works for key-less source profiles).
    func forkBrowserSession(_ row: GatewaySessions.Info) {
        Task {
            let agent = settings.profile
            let newId = ProfileLogic.newSessionId(agent)
            do {
                let r = try await settings.watchkit.forkSession(fromProfile: row.profile.isEmpty ? agent : row.profile,
                                                                 sessionId: row.id, toProfile: agent, newId: newId)
                resumeGatewaySession(newId, title: SessionManage.chatLabel(row.title), sourceProfile: agent)
                refreshGatewaySessions()
                toast = "forked \(r.copiedMessages) msgs"
            } catch {
                toast = String(explain(error).prefix(140))
            }
        }
    }

    func deleteBrowserSession(_ row: GatewaySessions.Info) {
        Task {
            do {
                _ = try await settings.watchkit.deleteSession(profile: row.profile.isEmpty ? settings.profile : row.profile, sessionId: row.id)
                if let mirror = SessionManage.localMirror(store.chats, sessionId: row.id) { deleteChat(mirror.id) }
                refreshGatewaySessions()
                toast = "deleted"
            } catch {
                toast = String(explain(error).prefix(140))
            }
        }
    }

    func archiveBrowserSession(_ row: GatewaySessions.Info, archived: Bool) {
        Task {
            do {
                try await settings.watchkit.archiveSession(profile: row.profile.isEmpty ? settings.profile : row.profile,
                                                           sessionId: row.id, archived: archived)
                refreshGatewaySessions()
                toast = archived ? "archived" : "unarchived"
            } catch {
                toast = String(explain(error).prefix(140))
            }
        }
    }

    /// Two passes: this watch's own chats instantly, then watchkit FTS for agent + desktop.
    func searchSessions(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; return }
        let local = SessionSearch.localHits(store.chats, q) { [store] in store.loadTranscript($0) }
        searchHits = local
        let wk = settings.watchkit
        let profiles = Array(Set([settings.profile, ProfileLogic.profileComputer]))
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // keystroke debounce
            guard !Task.isCancelled else { return }
            var gateway: [SessionHit] = []
            for p in profiles { gateway += (try? await wk.search(q, profile: p)) ?? [] }
            guard !Task.isCancelled else { return }
            searchHits = SessionSearch.merge(local: local, gateway: gateway)
        }
    }

    func openSearchHit(_ hit: SessionHit) {
        if hit.source == .watch { openChat(hit.watchChatId) }
        else { openSessionRow(GatewaySessions.Info(id: hit.id, title: hit.title, lastActiveMs: hit.lastActiveMs, messages: 0, profile: hit.profile)) }
    }
}

/// nil on timeout or error — history probes are a leash, not a budget.
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await op() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
