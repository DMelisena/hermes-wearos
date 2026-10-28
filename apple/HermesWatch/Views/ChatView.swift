import HermesCore
import SwiftUI

/// The chat screen: transcript, the live answer streaming in, approval card, and the orb.
/// Tap the orb → system dictation/scribble/keyboard (watchOS text input) → ask; tap it while a
/// run streams → STOP. Every other lane (chats, sessions, agents, model, slash verbs, settings)
/// lives behind the ☰ toolbar button, the Apple Watch stand-in for the Wear OS orb dial.
struct ChatView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var settings: AppSettings
    @State private var editing: ChatMessage?

    private var s: ChatSession.UIState { session.state }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    header
                    ForEach(s.messages) { m in
                        MessageRow(message: m)
                            .onLongPressGesture { if m.role == .User { editing = m } }
                    }
                    if !s.live.isEmpty { MessageRow(message: ChatMessage(id: -1, role: .Hermes, text: s.live)) }
                    if !s.status.isEmpty {
                        Text(s.status).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let ap = s.approval { ApprovalCard(info: ap) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: s.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: s.live.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: s.approval) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .navigationTitle(settings.profile)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { MenuView() } label: { Image(systemName: "line.3.horizontal") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { session.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(s.busy)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Orb()
                Spacer()
            }
        }
        .sheet(item: $editing) { m in EditPromptView(message: m) }
        .toastOverlay()
    }

    private var header: some View {
        let chat = s.activeChatLabel.isEmpty ? "new chat" : s.activeChatLabel
        let started = !s.messages.isEmpty
        return Text("\(started ? "●" : "○") \(chat)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }
}

/// The one primary control: ask when idle, stop while a run streams.
struct Orb: View {
    @EnvironmentObject private var session: ChatSession

    var body: some View {
        if session.state.busy {
            Button { session.stopActiveRun() } label: {
                Image(systemName: "stop.fill").font(.title3)
            }
            .tint(.red)
            .accessibilityLabel("Stop")
        } else {
            TextFieldLink(prompt: Text("Ask Hermes")) {
                Image("Orb").resizable().scaledToFit().frame(width: 34, height: 34)
            } onSubmit: { session.submit($0) }
            .accessibilityLabel("Ask")
        }
    }
}

struct ApprovalCard: View {
    @EnvironmentObject private var session: ChatSession
    let info: ApprovalInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Approval", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
            Text(info.question).font(.footnote.monospaced()).lineLimit(6)
            ForEach(Array(info.choices.enumerated()), id: \.offset) { i, choice in
                Button(choice) { session.respondApproval(choice) }
                    .tint(i == 0 ? .green : (i == info.choices.count - 1 ? .red : .gray))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
    }
}

/// Edit an old prompt → fork-and-redo (SPEC §12.5).
struct EditPromptView: View {
    @EnvironmentObject private var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                TextField("Prompt", text: $text)
                Button("Resend") {
                    session.editAndResend(message.id, text)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Redo branches the gateway session; the old answer stays in the model's context.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = message.text }
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

private struct ToastOverlay: ViewModifier {
    @EnvironmentObject private var session: ChatSession

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = session.toast {
                Text(t)
                    .font(.caption2)
                    .padding(6)
                    .background(Capsule().fill(.thinMaterial))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if session.toast == t { session.toast = nil }
                    }
            }
        }
    }
}
