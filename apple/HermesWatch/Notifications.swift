import Foundation
import HermesCore
import UserNotifications

/// Local notifications for answers that settle / approvals that park while the app is not on
/// screen (port of `notify/Notifs.kt`). Approvals carry inline Approve/Deny actions.
enum Notifications {
    static let approvalCategory = "hermes.approval"
    static let answerCategory = "hermes.answer"
    static let approveAction = "hermes.approve"
    static let denyAction = "hermes.deny"

    static func register() {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve", options: [])
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: answerCategory, actions: [], intentIdentifiers: []),
        ])
    }

    private static func post(id: String, title: String, body: String, category: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func approval(chatId: String, info: ApprovalInfo) {
        post(id: "approval-\(info.runId)", title: "Approval needed", body: info.question, category: approvalCategory,
             info: ["chatId": chatId, "runId": info.runId])
    }

    static func settle(chatId: String, label: String, text: String, error: Bool) {
        post(id: "answer-\(chatId)", title: error ? "Hermes · failed" : (label.isEmpty ? "Hermes" : label),
             body: WatchMarkdown.speakable(text), category: answerCategory, info: ["chatId": chatId])
    }

    static func cancelApproval(_ runId: String) {
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: ["approval-\(runId)"])
        c.removePendingNotificationRequests(withIdentifiers: ["approval-\(runId)"])
    }

    static func cancelChat(_ chatId: String) {
        guard !chatId.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["answer-\(chatId)"])
    }
}

/// Routes notification taps/actions into the chat engine.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    @MainActor weak var session: ChatSession?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let chatId = info["chatId"] as? String ?? ""
        let runId = info["runId"] as? String ?? ""
        let action = response.actionIdentifier
        await MainActor.run {
            guard let session else { return }
            switch action {
            case Notifications.approveAction, Notifications.denyAction:
                Task { await session.respondApprovalFromNotification(runId: runId, approve: action == Notifications.approveAction) }
            default:
                if !chatId.isEmpty { session.openFromNotification(chatId) }
            }
        }
    }

    // Foreground: the in-app card already shows it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
