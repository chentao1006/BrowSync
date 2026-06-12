// NotificationService.swift
// BrowSync — Local notifications via UNUserNotificationCenter

import Foundation
import UserNotifications
import os.log

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "NotificationService")

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        do {
            let options: UNAuthorizationOptions = [.alert, .sound, .badge]
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            logger.info("Notification permission granted: \(granted)")
        } catch {
            logger.error("Failed to request notification permission: \(error.localizedDescription)")
        }
    }

    private var langBundle: Bundle {
        LanguageBundle(language: AppState.shared.settingsService.general.language).bundle
    }

    func notifySyncComplete(stats: SyncStats, categories: [SyncCategory]) {
        Task {
            await requestPermission()
            let content = UNMutableNotificationContent()
            
            let hasBookmarks = categories.contains(where: { $0.rawValue == "bookmarks" })
            let hasState = categories.contains(where: { $0.rawValue != "bookmarks" })
            
            if hasBookmarks && !hasState {
                content.title = String(localized: "Bookmark Sync Complete", bundle: langBundle)
                content.body = String(format: String(localized: "Successfully synced %d bookmarks.", bundle: langBundle), stats.bookmarks)
            } else if hasState && !hasBookmarks {
                content.title = String(localized: "State Sync Complete", bundle: langBundle)
                let storageCount = stats.localStorage + stats.sessionStorage
                content.body = String(format: String(localized: "Successfully synced %d cookies and %d storage items.", bundle: langBundle), stats.cookies, storageCount)
            } else {
                content.title = String(localized: "BrowSync Complete", bundle: langBundle)
                let storageCount = stats.cookies + stats.localStorage + stats.sessionStorage
                content.body = String(format: String(localized: "Synced %d bookmarks and %d state items.", bundle: langBundle), stats.bookmarks, storageCount)
            }
            
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self.logger.error("Failed to schedule sync complete notification: \(error.localizedDescription)")
            }
        }
    }

    func notifyBrowserConnected(_ browser: Browser) {
        Task {
            await requestPermission()
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Browser Connected", bundle: langBundle)
            content.body = String(format: String(localized: "%@ is now connected and ready to sync.", bundle: langBundle), browser.displayName)
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self.logger.error("Failed to schedule browser connected notification: \(error.localizedDescription)")
            }
        }
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }
}
