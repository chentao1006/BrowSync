// NotificationService.swift
// BrowSync — Local notifications via UNUserNotificationCenter

import Foundation
import AppKit
import UserNotifications
import os.log

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let emptyBookmarkSnapshotCategory = "browsync.empty-bookmark-snapshot"
    private static let forceEmptyBookmarkSnapshotAction = "browsync.force-empty-bookmark-snapshot"
    private static let openRecentBackupsAction = "browsync.open-recent-bookmark-backups"
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "NotificationService")
    /// Some sites continuously rewrite storage for analytics, sessions, or
    /// heartbeats. Showing a completion banner for every one of those writes
    /// makes automatic sync unusable, so report each site's background activity
    /// at most once per cooldown window.
    private static let autoStateSyncNotificationCooldown: TimeInterval = 5 * 60
    private var pendingAutoSyncStats = SyncStats()
    private var pendingAutoSyncCategories = Set<SyncCategory>()
    private var autoSyncNotificationTask: Task<Void, Never>?
    private var lastAutoStateSyncNotificationBySite: [String: Date] = [:]

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

    /// Opening a page commonly yields separate cookie and storage payloads.
    /// Combine automatic results that arrive as part of one user action into a
    /// single completion notification. Bookmark changes are already reduced to
    /// safe deltas by SyncService, so they must be accumulated rather than
    /// allowing a later delete/update message to overwrite an earlier add.
    func notifyAutoSyncComplete(stats: SyncStats, categories: [SyncCategory]) {
        if categories.contains(.bookmarks) {
            pendingAutoSyncStats.bookmarks += stats.bookmarks
            pendingAutoSyncStats.bookmarkFolders += stats.bookmarkFolders
            pendingAutoSyncStats.bookmarksAdded += stats.bookmarksAdded
            pendingAutoSyncStats.bookmarksDeleted += stats.bookmarksDeleted
            pendingAutoSyncStats.bookmarksModified += stats.bookmarksModified
            pendingAutoSyncStats.bookmarkFoldersAdded += stats.bookmarkFoldersAdded
            pendingAutoSyncStats.bookmarkFoldersDeleted += stats.bookmarkFoldersDeleted
            pendingAutoSyncStats.bookmarkFoldersModified += stats.bookmarkFoldersModified
        }
        pendingAutoSyncStats.tabs += stats.tabs
        pendingAutoSyncStats.cookies += stats.cookies
        pendingAutoSyncStats.localStorage += stats.localStorage
        pendingAutoSyncStats.sessionStorage += stats.sessionStorage
        pendingAutoSyncStats.syncedSites.formUnion(stats.syncedSites)
        pendingAutoSyncCategories.formUnion(categories)

        autoSyncNotificationTask?.cancel()
        autoSyncNotificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }

            let combinedStats = self.pendingAutoSyncStats
            let combinedCategories = Array(self.pendingAutoSyncCategories)
            self.pendingAutoSyncStats = SyncStats()
            self.pendingAutoSyncCategories = []
            self.autoSyncNotificationTask = nil

            guard self.shouldNotifyAutoSync(stats: combinedStats, categories: combinedCategories) else {
                return
            }
            self.notifySyncComplete(stats: combinedStats, categories: combinedCategories)
        }
    }

    private func shouldNotifyAutoSync(stats: SyncStats, categories: [SyncCategory]) -> Bool {
        let includesState = categories.contains { $0.rawValue != "bookmarks" }
        guard includesState, !stats.syncedSites.isEmpty else { return true }

        let now = Date()
        lastAutoStateSyncNotificationBySite = lastAutoStateSyncNotificationBySite.filter {
            now.timeIntervalSince($0.value) < Self.autoStateSyncNotificationCooldown
        }
        let sitesToNotify = stats.syncedSites.filter { site in
            guard let lastNotification = lastAutoStateSyncNotificationBySite[site] else { return true }
            return now.timeIntervalSince(lastNotification) >= Self.autoStateSyncNotificationCooldown
        }

        guard !sitesToNotify.isEmpty else {
            logger.debug("Suppressed repeated automatic state-sync notification for: \(stats.syncedSites.sorted().joined(separator: ", "))")
            return false
        }

        for site in stats.syncedSites {
            lastAutoStateSyncNotificationBySite[site] = now
        }
        return true
    }

    func notifySyncComplete(stats: SyncStats, categories: [SyncCategory]) {
        Task {
            let hasBookmarks = categories.contains(where: { $0.rawValue == "bookmarks" })
            let hasState = categories.contains(where: { $0.rawValue != "bookmarks" })
            let storageCount = stats.localStorage + stats.sessionStorage
            var bookmarkParts: [String] = []
            if stats.bookmarksAdded > 0 { bookmarkParts.append(String(format: String(localized: "Added %d bookmarks", bundle: langBundle), stats.bookmarksAdded)) }
            if stats.bookmarkFoldersAdded > 0 { bookmarkParts.append(String(format: String(localized: "Added %d folders", bundle: langBundle), stats.bookmarkFoldersAdded)) }
            if stats.bookmarksDeleted > 0 { bookmarkParts.append(String(format: String(localized: "Deleted %d bookmarks", bundle: langBundle), stats.bookmarksDeleted)) }
            if stats.bookmarkFoldersDeleted > 0 { bookmarkParts.append(String(format: String(localized: "Deleted %d folders", bundle: langBundle), stats.bookmarkFoldersDeleted)) }
            if stats.bookmarksModified > 0 { bookmarkParts.append(String(format: String(localized: "Modified %d bookmarks", bundle: langBundle), stats.bookmarksModified)) }
            if stats.bookmarkFoldersModified > 0 { bookmarkParts.append(String(format: String(localized: "Modified %d folders", bundle: langBundle), stats.bookmarkFoldersModified)) }

            if hasBookmarks && !hasState {
                guard !bookmarkParts.isEmpty else { return }
            } else if hasState && !hasBookmarks {
                guard stats.cookies > 0 || storageCount > 0 else { return }
            } else {
                guard !bookmarkParts.isEmpty || stats.cookies > 0 || storageCount > 0 else { return }
            }

            await requestPermission()
            let content = UNMutableNotificationContent()

            if hasBookmarks && !hasState {
                content.title = String(localized: "Bookmark Sync Complete", bundle: langBundle)
                content.body = bookmarkParts.joined(separator: ", ")
            } else if hasState && !hasBookmarks {
                content.title = String(localized: "State Sync Complete", bundle: langBundle)
                var parts: [String] = []
                if stats.cookies > 0 { parts.append(String(format: String(localized: "%d cookies", bundle: langBundle), stats.cookies)) }
                if storageCount > 0 { parts.append(String(format: String(localized: "%d storage items", bundle: langBundle), storageCount)) }
                content.body = String(format: String(localized: "Successfully synced %@.", bundle: langBundle), parts.joined(separator: ", "))
            } else {
                content.title = String(localized: "BrowSync Complete", bundle: langBundle)
                var parts: [String] = []
                parts.append(contentsOf: bookmarkParts)
                if stats.cookies > 0 { parts.append(String(format: String(localized: "%d cookies", bundle: langBundle), stats.cookies)) }
                if storageCount > 0 { parts.append(String(format: String(localized: "%d storage items", bundle: langBundle), storageCount)) }
                content.body = String(format: String(localized: "Synced %@.", bundle: langBundle), parts.joined(separator: ", "))
            }

            if !stats.syncedSites.isEmpty {
                let sites = stats.syncedSites.sorted().joined(separator: ", ")
                content.body += "\n" + String(format: String(localized: "Synced Websites: %@", bundle: langBundle), sites)
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

    func notifyBookmarkSyncFailed(browser: Browser, folder: String) {
        Task {
            await requestPermission()
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Bookmark Sync Failed", bundle: langBundle)
            content.body = String(format: String(localized: "The selected folder for %@ no longer exists: %@", bundle: langBundle), browser.displayName, folder)
            content.userInfo = [
                "browsyncAction": "openBookmarkFolderManager",
                "browser": browser.rawValue
            ]
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self.logger.error("Failed to schedule bookmark sync failure notification: \(error.localizedDescription)")
            }
        }
    }

    func notifyUnexpectedEmptyBookmarkSnapshot(source: String, previousCount: Int) {
        Task {
            let forceAction = UNNotificationAction(
                identifier: Self.forceEmptyBookmarkSnapshotAction,
                title: String(localized: "Force Sync", bundle: langBundle),
                options: [.destructive]
            )
            let backupsAction = UNNotificationAction(
                identifier: Self.openRecentBackupsAction,
                title: String(localized: "Open Recent Automatic Backups", bundle: langBundle),
                options: [.foreground]
            )
            let category = UNNotificationCategory(
                identifier: Self.emptyBookmarkSnapshotCategory,
                actions: [forceAction, backupsAction],
                intentIdentifiers: [],
                options: []
            )
            UNUserNotificationCenter.current().setNotificationCategories([category])
            await requestPermission()

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Bookmark Sync Blocked", bundle: langBundle)
            content.body = String(
                format: String(localized: "%@ returned an empty bookmark snapshot, but the previous snapshot contained %d items. Nothing was changed.", bundle: langBundle),
                source,
                previousCount
            )
            content.categoryIdentifier = Self.emptyBookmarkSnapshotCategory
            content.userInfo = ["clientId": source]
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self.logger.error("Failed to schedule empty bookmark snapshot warning: \(error.localizedDescription)")
            }
        }
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionIdentifier = response.actionIdentifier
        let clientId = response.notification.request.content.userInfo["clientId"] as? String
        let shouldOpenFolderManager = response.notification.request.content.userInfo["browsyncAction"] as? String == "openBookmarkFolderManager"
        await MainActor.run {
            if actionIdentifier == Self.forceEmptyBookmarkSnapshotAction, let clientId {
                AppState.shared.syncService.forceAcceptPendingEmptyBookmarkSnapshot(from: clientId)
                return
            }
            if actionIdentifier == Self.openRecentBackupsAction {
                _ = AppDelegate.shared?.showExistingSettingsWindowIfPossible()
                AppState.shared.requestOpenRecentBookmarkBackups()
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            guard shouldOpenFolderManager else { return }
            _ = AppDelegate.shared?.showExistingSettingsWindowIfPossible()
            AppState.shared.requestOpenBookmarkFolderManager()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
