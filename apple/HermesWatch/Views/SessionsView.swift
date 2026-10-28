import HermesCore
import SwiftUI

/// Cross-profile gateway sessions (SPEC §3): this agent + the desktop (`default`) newest-first,
/// profile chips, 🗃 archived, search; swipe a row to archive / fork / delete (double-checked).
struct SessionsView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var filter = GatewaySessions.filterAll
    @State private var query = ""
    @State private var doomed: GatewaySessions.Info?

    private var rows: [GatewaySessions.Info] {
        filter == GatewaySessions.filterArchived ? session.archivedSessions
            : GatewaySessions.filterProfile(session.gatewaySessions, filter)
    }

    var body: some View {
        List {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(session.searchHits) { h in
                    Button { session.openSearchHit(h); dismiss() } label: {
                        VStack(alignment: .leading) {
                            Text("\(h.source == .watch ? "⌚ " : "")\(h.title)").lineLimit(1)
                            Text(h.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            } else {
                chips
                Button { session.newChat(); dismiss() } label: { Label("New session", systemImage: "plus") }
                if session.sessionsMeta.stale {
                    Text("offline · cached list").font(.caption2).foregroundStyle(.orange)
                }
                ForEach(rows) { r in
                    Button { session.openSessionRow(r); dismiss() } label: { SessionRow(row: r) }
                        .swipeActions {
                            Button(role: .destructive) { doomed = r } label: { Image(systemName: "trash") }
                            Button { session.archiveBrowserSession(r, archived: !r.archived) } label: {
                                Image(systemName: r.archived ? "tray.and.arrow.up" : "archivebox")
                            }
                            Button { session.forkBrowserSession(r); dismiss() } label: { Image(systemName: "arrow.branch") }
                        }
                }
            }
        }
        .navigationTitle("Sessions")
        .searchable(text: $query)
        .onChange(of: query) { _, q in session.searchSessions(q) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { session.refreshGatewaySessions() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear { session.refreshGatewaySessions() }
        .confirmationDialog("Delete for good?", isPresented: Binding(get: { doomed != nil }, set: { if !$0 { doomed = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = doomed { session.deleteBrowserSession(d) }
                doomed = nil
            }
        } message: {
            Text("\(doomed?.title ?? "") — messages are removed from the gateway store. Archive hides instead.")
        }
        .toastOverlay()
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("all", GatewaySessions.filterAll)
                ForEach(GatewaySessions.profilesIn(session.gatewaySessions), id: \.self) { chip(ProfileLogic.chipLabel($0), $0) }
                if !session.archivedSessions.isEmpty { chip("🗃", GatewaySessions.filterArchived) }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func chip(_ title: String, _ value: String) -> some View {
        Button(title) { filter = value }
            .font(.caption2)
            .buttonStyle(.bordered)
            .tint(filter == value ? .accentColor : .gray)
    }
}

private struct SessionRow: View {
    let row: GatewaySessions.Info

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(ProfileLogic.isWatchSession(row.id) ? "⌚ " : "")\(row.title.isEmpty ? row.id : row.title)").lineLimit(2)
            HStack {
                Text(ProfileLogic.chipLabel(row.profile))
                Text("· \(row.messages) msgs")
                Text("· \(relative(row.lastActiveMs))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}
