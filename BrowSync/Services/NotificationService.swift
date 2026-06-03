// NotificationService.swift
// BrowSync — Local notifications via UNUserNotificationCenter

import Foundation
import UserNotifications
import os.log

@MainActor
final class NotificationService {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "NotificationService")

    func requestPermission() async {
        // Disabled
    }

    func notifySyncComplete(categories: [SyncCategory]) {
        // Disabled
    }

    func notifyBrowserConnected(_ browser: Browser) {
        // Disabled
    }
}
