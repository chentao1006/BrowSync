// NotificationService.swift
// BrowSync — Local notifications via UNUserNotificationCenter

import Foundation
import UserNotifications
import os.log

@MainActor
final class NotificationService {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "NotificationService")

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            logger.info("Notification permission granted: \(granted)")
        } catch {
            logger.error("Notification permission error: \(error)")
        }
    }

    func notifySyncComplete(categories: [SyncCategory]) {
        let body = categories.map(\.displayName).joined(separator: ", ")
        send(
            id: "sync.complete",
            title: String(localized: "Sync Complete"),
            body: String(localized: "Synced: \(body)")
        )
    }

    func notifyBrowserConnected(_ browser: Browser) {
        send(
            id: "browser.connected.\(browser.rawValue)",
            title: String(localized: "Browser Connected"),
            body: String(localized: "\(browser.displayName) is now connected to BrowSync")
        )
    }

    func notifyRuleMatch(rule: BrowserRule, url: URL, browser: Browser) {
        send(
            id: "rule.match",
            title: String(localized: "Rule Matched"),
            body: String(localized: "'\(rule.name)' → \(browser.displayName): \(url.host ?? url.absoluteString)")
        )
    }

    private func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: id + "-" + UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to deliver notification: \(error)")
            }
        }
    }
}
