import HermesCore
import SwiftUI

/// Every lane the Wear OS orb dial carried (SPEC §12 D1–D8), as one list.
struct MenuView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            NavigationLink { ChatsView() } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            NavigationLink { SessionsView() } label: { Label("Sessions", systemImage: "clock.arrow.circlepath") }
            NavigationLink { AgentsView() } label: {
                Label("Agent · \(ProfileLogic.shortLabel(settings.profile))", systemImage: "person.crop.circle")
            }
            NavigationLink { ModelPickerView() } label: {
                Label("Model · \(session.pickedModel.isEmpty ? "default" : ModelCatalog.shortName(session.pickedModel))",
                      systemImage: "brain")
            }
            Section("Commands") {
                TextFieldLink(prompt: Text("Aside on a forked branch")) {
                    Label("/btw", systemImage: "arrow.triangle.branch")
                } onSubmit: { session.sideAsk($0); dismiss() }
                if session.state.busy {
                    TextFieldLink(prompt: Text("Guide the run in flight")) {
                        Label("/steer", systemImage: "steeringwheel")
                    } onSubmit: { session.steer($0); dismiss() }
                    .disabled(session.capabilities["run_steer"] == false)
                }
                Button { session.forkActive(); dismiss() } label: { Label("/fork", systemImage: "arrow.branch") }
                    .disabled(session.capabilities["session_fork"] == false)
                Button { session.catchUpActive(manual: true); dismiss() } label: {
                    Label("Sync from gateway", systemImage: "arrow.down.circle")
                }
            }
            NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
        }
        .navigationTitle("Hermes")
    }
}

struct ChatsView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ChatMeta?

    private var mine: [ChatMeta] {
        store.chats.filter { $0.profile == settings.profile }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            Button { session.newChat(); dismiss() } label: { Label("New chat", systemImage: "plus") }
            ForEach(mine) { c in
                Button { session.openChat(c.id); dismiss() } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            if c.pendingAttention { Circle().fill(.orange).frame(width: 6, height: 6) }
                            Text(c.displayLabel).lineLimit(1)
                            if c.id == store.activeId { Image(systemName: "checkmark").font(.caption2) }
                        }
                        Text(relative(c.updatedAt)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { session.deleteChat(c.id) } label: { Image(systemName: "trash") }
                    Button { renaming = c } label: { Image(systemName: "pencil") }
                }
            }
        }
        .navigationTitle("Chats")
        .sheet(item: $renaming) { c in RenameView(chat: c) }
    }
}

private struct RenameView: View {
    @EnvironmentObject private var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    let chat: ChatMeta
    @State private var label = ""

    var body: some View {
        VStack {
            TextField("Label", text: $label)
            Button("Save") { session.renameChat(chat.id, label); dismiss() }
        }
        .onAppear { label = chat.label }
    }
}

func relative(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: Date())
}

struct AgentsView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(ProfileLogic.displayAgents(settings.agentsCache, current: settings.profile), id: \.self) { a in
                Button {
                    session.switchAgent(a)
                    dismiss()
                } label: {
                    HStack {
                        Text(ProfileLogic.chipLabel(a))
                        Spacer()
                        if a == settings.profile { Image(systemName: "checkmark") }
                        else if settings.selectedGateway?.agentKeys[a] == nil && settings.selectedGateway?.token.isEmpty != false {
                            Image(systemName: "key.slash").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Agents")
        .task { await session.refreshAgents() }
    }
}

struct ModelPickerView: View {
    @EnvironmentObject private var session: ChatSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = session.modelState
        List {
            Button { session.pickModel(""); dismiss() } label: {
                row("Gateway default\(m.catalog.map { $0.defaultModel.isEmpty ? "" : " · \(ModelCatalog.shortName($0.defaultModel))" } ?? "")",
                    picked: m.picked.isEmpty)
            }
            if m.loading { ProgressView() }
            if !m.error.isEmpty { Text(m.error).font(.caption2).foregroundStyle(.red) }
            ForEach(m.catalog?.groups ?? [], id: \.provider) { g in
                Section(g.name) {
                    ForEach(g.models, id: \.self) { model in
                        Button { session.pickModel(model); dismiss() } label: {
                            row(ModelCatalog.shortName(model), picked: m.picked == model)
                        }
                    }
                }
            }
        }
        .navigationTitle("Model")
        .onAppear { session.refreshModels() }
    }

    private func row(_ title: String, picked: Bool) -> some View {
        HStack {
            Text(title).lineLimit(2)
            Spacer()
            if picked { Image(systemName: "checkmark") }
        }
    }
}
