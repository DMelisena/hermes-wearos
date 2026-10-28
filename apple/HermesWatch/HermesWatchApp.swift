import HermesCore
import SwiftUI
import UserNotifications

@main
struct HermesWatchApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: ChatStore
    @StateObject private var session: ChatSession

    init() {
        let s = AppSettings()
        let st = ChatStore()
        let cs = ChatSession(settings: s, store: st)
        _settings = StateObject(wrappedValue: s)
        _store = StateObject(wrappedValue: st)
        _session = StateObject(wrappedValue: cs)
        NotificationRouter.shared.session = cs
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        Notifications.register()
        cs.resume()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(session)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: ChatSession
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack { ChatView() }
            .onChange(of: phase) { _, p in
                if p == .active { session.onForeground() } else { session.isForeground = false }
            }
    }
}
