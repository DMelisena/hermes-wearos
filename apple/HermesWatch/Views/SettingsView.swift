import HermesCore
import SwiftUI

/// Settings tree (SPEC §4): gateways with endpoint winner dots, test, agent keys, watchkit
/// bearer, voice/markdown toggles. Nothing is baked into the build.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var testResult = ""
    @State private var testing = false
    @State private var keysNote = ""

    var body: some View {
        List {
            Section("Gateways") {
                ForEach(settings.gateways) { g in
                    NavigationLink { GatewayEditView(original: g) } label: {
                        HStack {
                            Image(systemName: g.id == settings.selectedGatewayId ? "largecircle.fill.circle" : "circle")
                            Text(g.label)
                        }
                    }
                    .swipeActions {
                        Button { settings.selectGateway(g.id) } label: { Image(systemName: "checkmark") }
                        Button(role: .destructive) { settings.deleteGateway(g.id) } label: { Image(systemName: "trash") }
                    }
                }
                NavigationLink { GatewayEditView(original: nil) } label: { Label("Add gateway", systemImage: "plus") }
            }
            if let gw = settings.selectedGateway {
                Section("Endpoints") {
                    ForEach(gw.apiEndpoints, id: \.self) { endpointRow($0, results: settings.endpointStatus.apiResults, winner: settings.endpointStatus.apiWinner) }
                    ForEach(gw.watchkitEndpoints, id: \.self) { endpointRow($0, results: settings.endpointStatus.watchkitResults, winner: settings.endpointStatus.watchkitWinner, tag: "wk") }
                    Button(testing ? "Testing…" : "Test") { test() }.disabled(testing)
                    if !testResult.isEmpty { Text(testResult).font(.caption2) }
                }
                Section("Agent keys") {
                    ForEach(ProfileLogic.displayAgents(settings.agentsCache, current: settings.profile), id: \.self) { a in
                        NavigationLink { AgentKeyView(agent: a) } label: {
                            HStack {
                                Text(a)
                                Spacer()
                                Text(gw.agentKeys[a] != nil ? "✓" : (gw.token.isEmpty ? "—" : "token")).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("⟳ Learn from watchkit") {
                        Task {
                            let n = await settings.refreshAgentKeys()
                            keysNote = n > 0 ? "\(n) keys known" : "watchkit unreachable or no keys"
                        }
                    }
                    if !keysNote.isEmpty { Text(keysNote).font(.caption2) }
                }
            }
            Section("watchkit") {
                SecureField("watchkit token", text: $settings.watchkitToken)
            }
            Section("Voice & display") {
                Toggle("Speak answers", isOn: $settings.voiceOut)
                Toggle("Markdown", isOn: $settings.markdown)
            }
        }
        .navigationTitle("Settings")
        .task { await settings.ensureEndpoints() }
    }

    private func endpointRow(_ ep: String, results: [String: Bool], winner: String, tag: String = "api") -> some View {
        let dot: String = ep == winner && results[ep] == true ? "●" : (results[ep] == false ? "✕" : "○")
        return HStack {
            Text(dot).foregroundStyle(results[ep] == false ? .red : .green)
            Text(Failover.host(ep)).font(.caption2).lineLimit(1)
            Spacer()
            Text(tag).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func test() {
        testing = true
        testResult = ""
        Task {
            await settings.ensureEndpoints(force: true)
            var lines: [String] = []
            do { lines.append("api ✅ \(try await settings.api().health())") }
            catch { lines.append("api ❌ \((error as? LocalizedError)?.errorDescription ?? "unreachable")") }
            do { _ = try await settings.api().capabilities(); lines.append("key ✅ \(settings.profile)") }
            catch { lines.append("key ❌ \(settings.profile): \((error as? ApiError)?.code ?? 0)") }
            do { lines.append("wk ✅ \(try await settings.watchkit.health())") }
            catch { lines.append("wk ❌ \((error as? LocalizedError)?.errorDescription ?? "unreachable")") }
            testResult = lines.joined(separator: "\n")
            testing = false
        }
    }
}

struct GatewayEditView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let original: Gateway?
    @State private var label = ""
    @State private var apis: [String] = [""]
    @State private var wks: [String] = [""]
    @State private var token = ""
    @State private var error = ""

    var body: some View {
        List {
            TextField("Label", text: $label)
            Section("API endpoints (first = default)") {
                ForEach(apis.indices, id: \.self) { i in
                    TextField("http://host:8642", text: $apis[i]).textContentType(.URL)
                }
                Button("+ endpoint") { apis.append("") }
            }
            Section("watchkit endpoints") {
                ForEach(wks.indices, id: \.self) { i in
                    TextField("http://host:8651", text: $wks[i]).textContentType(.URL)
                }
                Button("+ endpoint") { wks.append(GatewayModel.derivedWatchkit(apis.last ?? "")) }
            }
            Section("Token (API_SERVER_KEY)") {
                SecureField("token", text: $token)
            }
            Button("Save & use") { save() }
            if !error.isEmpty { Text(error).font(.caption2).foregroundStyle(.red) }
        }
        .navigationTitle(original?.label ?? "New gateway")
        .onAppear {
            guard let g = original else { return }
            label = g.label
            apis = g.apiEndpoints.isEmpty ? [""] : g.apiEndpoints
            wks = g.watchkitEndpoints.isEmpty ? [""] : g.watchkitEndpoints
            token = g.token
        }
    }

    private func save() {
        var wkList = wks
        if wkList.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            wkList = apis.map(GatewayModel.derivedWatchkit)
        }
        let gw = Gateway(id: original?.id ?? "", label: label, apiEndpoints: apis, watchkitEndpoints: wkList,
                         token: token, agentKeys: original?.agentKeys ?? [:])
        do {
            try settings.saveGateway(gw, select: true)
            dismiss()
        } catch {
            self.error = "needs at least one API endpoint"
        }
    }
}

private struct AgentKeyView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let agent: String
    @State private var key = ""

    var body: some View {
        VStack {
            SecureField("API_SERVER_KEY for \(agent)", text: $key)
            Button("Save") { settings.setAgentKey(agent, key: key); dismiss() }
            Text("Empty = fall back to the gateway token.").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { key = settings.selectedGateway?.agentKeys[agent] ?? "" }
    }
}
