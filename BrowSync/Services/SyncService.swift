// SyncService.swift
// BrowSync — Orchestrates sync operations between browsers via the Daemon

import Foundation
import AppKit
import os.log
import CryptoKit

extension Notification.Name {
    static let browSyncDidComplete = Notification.Name("BrowSyncDidComplete")
}

struct SyncStats {
    var bookmarks: Int = 0
    var bookmarkFolders: Int = 0
    var bookmarksAdded: Int = 0
    var bookmarksDeleted: Int = 0
    var bookmarksModified: Int = 0
    var bookmarkFoldersAdded: Int = 0
    var bookmarkFoldersDeleted: Int = 0
    var bookmarkFoldersModified: Int = 0
    
    var tabs: Int = 0
    var cookies: Int = 0
    var localStorage: Int = 0
    var sessionStorage: Int = 0
    /// Domains/origins included in this sync, for the completion notification.
    var syncedSites = Set<String>()
    /// Browsers where the reported bookmark changes originated.
    var bookmarkSourceBrowserIds = Set<String>()
    
    var stateItems: Int { cookies + localStorage + sessionStorage }
    var isEmpty: Bool {
        bookmarks == 0 && bookmarkFolders == 0 && tabs == 0 && stateItems == 0 &&
        bookmarksAdded == 0 && bookmarksDeleted == 0 && bookmarksModified == 0 &&
        bookmarkFoldersAdded == 0 && bookmarkFoldersDeleted == 0 && bookmarkFoldersModified == 0
    }
}

@MainActor
final class SyncService: ObservableObject {
    private struct PendingEmptyBookmarkSnapshot {
        let message: WSMessage
        let clientId: String
    }
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SyncService")
    private let dataDir: URL
    private static let syncLogRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let syncLogMaximumBytes = 10 * 1024 * 1024

    @Published var lastSyncDate: Date? = nil
    @Published var isSyncing: Bool = false
    @Published private(set) var lastManualSyncWasCancelled = false
    @Published var syncLog: [SyncLogEntry] = []
    /// Bookmark count per browser ID (e.g. "safari", "chrome"). Updated on sync.
    @Published var bookmarkCounts: [String: Int] = [:]
    
    private var currentManualSyncStats = SyncStats()
    private var activeManualSyncID: UUID?

    /// One bookmark sync pass: every source's changes since its per-target
    /// baseline, one native context per target, one aggregate review and one
    /// verified write per target.
    struct BookmarkSyncSession {
        enum Phase { case collecting, reviewing, applying, finalizing }
        let id = UUID()
        let manual: Bool
        let settingsFingerprint: String
        var phase: Phase = .collecting
        /// Newest snapshot of every participant at session start.
        var observed: [Browser: [Bookmark]] = [:]
        /// Changes per source -> target pair, relative to that pair's baseline.
        var deltas: [String: BookmarkSnapshotDelta] = [:]
        var contexts: [Browser: BookmarkNativeTreeContext] = [:]
        var clientIds: [Browser: String] = [:]
        var awaitingContexts: [String: Browser] = [:]
        var conflicts: [BookmarkSyncConflict] = []
        var plans: [Browser: BookmarkTargetPlan] = [:]
        /// Plans computed with the user's choices, and what was sent from them.
        var appliedPlans: [Browser: BookmarkTargetPlan] = [:]
        /// Plans before ignored rows were removed; used to keep ignored
        /// changes pending instead of treating them as synchronized.
        var rawPlans: [Browser: BookmarkTargetPlan] = [:]
        var appliedRawPlans: [Browser: BookmarkTargetPlan] = [:]
        var dispatched: [Browser: [BookmarkMutationOperation]] = [:]
        var outstandingWrites: [String: Browser] = [:]
        var verified: Set<Browser> = []
        var resolutionsApplied = false
        var awaitingFreshSnapshots: Set<Browser> = []
        var finalizedSources: Set<Browser> = []
        var baselines: [String: [Bookmark]] = [:]
        /// Differences between live trees that no pending change explains.
        var reconciliation = BookmarkReconciliation()
        /// Ignore list the plans were filtered with (fixed for the approval).
        var ignored: Set<String> = []

        static func pairKey(_ source: Browser, _ target: Browser) -> String { "\(source.rawValue)>\(target.rawValue)" }
    }
    var bookmarkSyncSession: BookmarkSyncSession?
    private var installedBrowserCache: [String: (installed: Bool, checkedAt: Date)] = [:]

    /// Result of restoring a backup into its own browser.
    struct BookmarkRestoreOutcome {
        let browser: Browser
        let added: Int
        let removed: Int
        let updated: Int
    }
    struct PendingBookmarkRestore {
        let browser: Browser
        let clientId: String
        let desired: [Bookmark]
        let replacing: Bool
        let targetFolder: String?
        let archiveFolder: String?
        let completion: (BookmarkRestoreOutcome?) -> Void
        var operations: [BookmarkMutationOperation] = []
    }
    /// Restores waiting for a native tree (by request ID) or a verified
    /// write result (by message ID).
    var pendingRestoreContexts: [String: PendingBookmarkRestore] = [:]
    /// "Back Up Now": browsers whose fresh snapshot is awaited.
    struct ManualBackupRun {
        let id = UUID()
        var waiting: Set<Browser> = []
        var succeeded: [Browser] = []
        var failed: [Browser] = []
        var completions: [(_ succeeded: [Browser], _ failed: [Browser]) -> Void]
    }
    var manualBackupRun: ManualBackupRun?
    var pendingRestoreWrites: [String: PendingBookmarkRestore] = [:]
    /// Restore dispatches whose result did not arrive in time. A late result
    /// still means the browser may have changed: its tree is re-read.
    var lateRestoreWrites: [String: String] = [:]
    var bookmarkSessionNeedsRerun = false
    var bookmarkSessionScheduleTask: Task<Void, Never>?
    static let bookmarkSessionReviewKey = "bookmark-sync"
    static let bookmarkSessionConflictRouteId = "bookmark-sync|conflicts"
    /// Review rows the user chose to ignore ("target|kind|content" keys and
    /// "conflict|id"). An ignored change is never planned again until its
    /// content differs; the list can be cleared in Bookmark Sync settings.
    private static let ignoredBookmarkChangesKey = "BrowSyncIgnoredBookmarkChanges"
    @Published private(set) var ignoredBookmarkChanges: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: SyncService.ignoredBookmarkChangesKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(ignoredBookmarkChanges).sorted(), forKey: Self.ignoredBookmarkChangesKey) }
    }
    // Browser snapshot replies are asynchronous and do not reference the
    // request ID. After cancelling a review, discard only this short reply
    // window so it cannot recreate the cancelled plan.
    private var ignoreBookmarkObservationsUntil: Date?
    private struct SilentBrowserDataPull {
        let requesterClientId: String
        let site: String?
        let expiresAt: Date
    }
    private var silentBrowserDataPulls: [SilentBrowserDataPull] = []
    private var pendingEmptyBookmarkSnapshots: [String: PendingEmptyBookmarkSnapshot] = [:]
    private var forceAcceptedEmptyBookmarkMessageIds = Set<String>()

    // Deletion events are not the only destructive path: a malformed tree can
    // relocate most of Safari's bookmarks without deleting any. Automatic writes
    // that would remove or move many existing items wait here for the user.
    private struct PendingSafariWrite {
        let sourceName: String
        let held: SafariBookmarkService.HeldWrite
        /// Set for a held backup restore, to recompute it if Safari changed.
        var restore: (bookmarks: [SyncBookmark], replacing: Bool)? = nil
        /// The bookmark sync settings the change was computed under. If they
        /// change (direction, source, participants, folders), the held change
        /// no longer describes a write the user configured, so it is dropped.
        var settingsFingerprint = ""
    }
    private var pendingSafariWrites: [String: PendingSafariWrite] = [:] {
        // The menu bar offers the review for as long as anything is held, so a
        // closed window or a dismissed notification never strands a change.
        didSet { publishPendingReviews() }
    }

    // Writes into other browsers are planned here from an extension-provided
    // native tree. Extensions only validate the input token, execute the
    // app-approved operations and report actual results.
    // Keyed "to:<clientId>" (a key without the prefix is a write into Safari).
    private struct PendingBrowserWrite {
        let message: WSMessage
        let impact: SafariBookmarkService.WriteImpact
        let preview: BookmarkChangePreview
        let settingsFingerprint: String
        var nativeOperations: [BookmarkMutationOperation]? = nil
    }
    private var pendingBrowserWrites: [String: PendingBrowserWrite] = [:] {
        didSet { publishPendingReviews() }
    }
    private struct PendingNativePlanInput {
        let message: WSMessage
        let clientId: String
        let browser: Browser
        /// A stable-snapshot reconciliation may only surface a conflict. It
        /// must never turn a quiet cross-browser difference into a write.
        let conflictOnly: Bool
    }
    private struct PendingBookmarkConflictResolution {
        let input: PendingNativePlanInput
        let context: BookmarkNativeTreeContext
        let desired: [Bookmark]
        let conflicts: [BookmarkConflict]
        /// Participating browsers that do not contain the disputed item still
        /// need the user-selected result. They are planned after the same
        /// aggregate decision; they must not disappear merely because they do
        /// not themselves form a two-sided conflict.
        var propagationTargets: [Browser] = []
        var resolutions: [String: BookmarkConflictResolution] = [:]
        var index = 0
    }
    private var pendingNativePlanInputs: [String: PendingNativePlanInput] = [:]
    private var pendingBookmarkConflictResolution: PendingBookmarkConflictResolution?
    private var dispatchedNativePlans: [String: [BookmarkMutationOperation]] = [:]
    private static let nativePlanContextTimeout: UInt64 = 30_000_000_000
    /// The last bookmark sync sent to each browser, to re-send after approval.
    private var lastBookmarkMessageByClient: [String: WSMessage] = [:]
    private var pendingDeletedRestoreByMessageId: [String: (ids: Set<String>, browser: Browser)] = [:]
    /// While a browser's incoming change is under review (or a removal batch
    /// to it is unanswered), its snapshots still show what is being reviewed
    /// (e.g. a folder deleted elsewhere). Merging them into Safari or
    /// forwarding them would undo the change before the user decides.
    private func isAwaitingReview(of clientId: String) -> Bool {
        pendingBrowserWrites["to:" + clientId] != nil
            || pendingBrowserWrites["to:rm:" + clientId] != nil
    }

    func publishPendingReviews() {
        let session = bookmarkSyncSession?.phase == .reviewing ? [Self.bookmarkSessionReviewKey] : []
        AppState.shared.pendingBookmarkReviewClientIds = session + (Array(pendingSafariWrites.keys) + Array(pendingBrowserWrites.keys)).sorted()
    }
    // A reviewed change the user approved but that could not be written as is
    // because Safari changed meanwhile. A fresh snapshot is requested; if it
    // yields exactly this change again (soon, under the same settings) it is
    // written without asking twice.
    private struct ApprovedSafariWrite {
        let signature: String
        let settingsFingerprint: String
        let expires: Date
    }
    private var approvedSafariWriteSignatures: [String: ApprovedSafariWrite] = [:]
    // Set by persist() while handling one incoming message: its Safari write
    // was held or refused, so the same tree must not reach other browsers.
    private var currentMessageSafariWriteWasHeld = false
    // Later snapshots from the same browser recompute the same change. Once the
    // user kept Safari as is, do not ask about that identical change again.
    // Persisted so a restart does not ask again about a change already refused.
    private static let rejectedSafariWritesKey = "BrowSyncRejectedSafariBookmarkWrites"
    private var rejectedSafariWriteSignatures: [String: String] =
        UserDefaults.standard.dictionary(forKey: SyncService.rejectedSafariWritesKey) as? [String: String] ?? [:] {
        didSet {
            UserDefaults.standard.set(rejectedSafariWriteSignatures, forKey: Self.rejectedSafariWritesKey)
            AppState.shared.pausedBookmarkSyncClientIds = rejectedBookmarkSyncClientIds
        }
    }
    /// Browsers whose refused change keeps their bookmark sync into Safari
    /// paused (in one-way sync nothing else brings them back in line).
    /// Safari's own refused deduplication pauses nothing, so it is not listed.
    var rejectedBookmarkSyncClientIds: [String] {
        // Refused deletion batches, Safari's own deduplication and restores
        // pause nothing else, so they get no "Resume" entry.
        rejectedSafariWriteSignatures.keys.filter { $0 != "Safari" && $0 != Self.restoreReviewKey && !$0.hasPrefix(Self.cleanupReviewKey) && !$0.hasPrefix("rm:") && !$0.hasPrefix("to:rm:") }.sorted()
    }

    /// "Chrome" rather than the instance ID "chrome-main", for the UI. Review
    /// keys ("to:…", "to:rm:…", "rm:…") name the browser in their last part.
    static func displayName(forClient clientId: String) -> String {
        if clientId.hasPrefix(cleanupReviewKey) { return "BrowSync" }
        if clientId == restoreReviewKey {
            return String(localized: "Backup", bundle: LanguageBundle(language: AppState.shared.settingsService.general.language).bundle)
        }
        let id = reviewTarget(clientId)
        return Browser(rawValue: id.components(separatedBy: "-").first ?? id)?.displayName ?? id
    }

    /// The browser instance a review key refers to.
    static func reviewTarget(_ key: String) -> String {
        key.components(separatedBy: ":").last ?? key
    }

    static let restoreReviewKey = "restore"
    static let cleanupReviewKey = "cleanup"
    static let leakedRootCleanupKey = "cleanup:leaked-roots"
    static let mobileCleanupKey = "cleanup:mobile"

    /// BrowSync's own repairs of Safari bookmarks follow the same rule as any
    /// write: a small one is applied, a large one is reviewed first.
    /// Maintenance repairs are proposals only: they are computed for the whole
    /// Safari library, so they run only when Safari syncs its whole library
    /// (no selected folder) and are always reviewed, whatever their size.
    private func runSafariCleanup(_ held: SafariBookmarkService.HeldWrite?, key: String) {
        guard let held, held.impact.affected > 0 else { return }
        guard BookmarkMaintenancePolicy.allowsSafariCleanup(settings: settings) else {
            log("Skipped Safari bookmark cleanup: bookmark sync is off, Safari is not participating, Safari is the read-only one-way source, or Safari syncs only a selected folder.")
            return
        }
        holdLargeSafariWrite(PendingSafariWrite(sourceName: "BrowSync cleanup", held: held), clientId: key)
    }

    private var safariMutationIsAuthorized: Bool {
        BookmarkWritePolicy.allowsWrite(to: .safari, settings: settings)
    }

    /// A refusal holds only under the settings it was made with; changing the
    /// direction, source, participants or folders gives the change a new look.
    private func rejectionKey(_ destructiveSignature: String) -> String {
        let settingsHash = SHA256.hash(data: Data(bookmarkSettingsFingerprint.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return destructiveSignature + "@" + settingsHash
    }
    private var loggedRejectedSafariWriteSkips = Set<String>()
    private var bookmarkChangeDebounceTasks: [String: Task<Void, Never>] = [:]

    var daemon: DaemonServer?
    var settingsService: SettingsService?
    /// A browser that is not installed cannot take part in bookmark sync,
    /// even if it is still ticked in saved settings (for example after it
    /// was uninstalled). LaunchServices lookups are cached briefly because
    /// `settings` is read very often.
    private func isInstalledForBookmarkSync(_ browser: Browser) -> Bool {
        if browser == .safari { return true }
        if let cached = installedBrowserCache[browser.id], Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached.installed
        }
        let installed = browser.isInstalledApp
        installedBrowserCache[browser.id] = (installed, Date())
        return installed
    }

    var settings: SyncSettings {
        var current = settingsService?.syncSettings ?? SyncSettings()
        current.bookmarkParticipatingBrowsers = current.bookmarkParticipatingBrowsers.filter(isInstalledForBookmarkSync)
        guard !AppState.shared.purchaseService.isProUnlocked else { return current }

        current.bookmarkParticipatingBrowsers = Set(Browser.allCases.filter {
            current.bookmarkParticipatingBrowsers.contains($0)
        }.prefix(ProLimits.freeSyncBrowserCount))
        current.stateParticipatingBrowsers = Set(Browser.allCases.filter {
            current.stateParticipatingBrowsers.contains($0)
        }.prefix(ProLimits.freeSyncBrowserCount))
        current.websiteSettings = ProLimits.limitedWebsiteSettings(current.websiteSettings, isProUnlocked: false)
        current.bookmarkAutoSync = false
        current.automaticSync = false
        return current
    }
    var backupService: BackupService?
    private let safariBookmarks = SafariBookmarkService()
    private var latestCookieVersions: [String: Double] = [:]
    private var latestCookieClients: [String: String] = [:]
    // Tracks cookie keys where the current winner is a tombstone (deletion).
    // When a live cookie beats a tombstone, the sender may have already had
    // its cookie deleted by the tombstone broadcast, so we must send it back.
    private var tombstoneWinnerKeys: Set<String> = []
    
    // Safari Bookmark Monitor
    private var safariMonitorSource: DispatchSourceFileSystemObject?
    private var safariMonitorFileDescriptor: Int32 = -1
    private var safariBookmarkDebounceTask: Task<Void, Never>?
    private var recentSafariPushByClient: [String: (bookmarks: [Bookmark], sentAt: Date)] = [:]
    private var lastNetworkSyncTime: Date = Date.distantPast
    private var suppressSafariPreSyncBackupUntil: Date = .distantPast
    @Published var missingBookmarkFolders: [String: String] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("BrowSync")
        createDataDirectories()
        removeLegacyRemovalQueues()
        loadBookmarkCountsFromDisk()
        // After launch, not during init: a large cleanup opens the review,
        // which needs AppState.shared (still being initialized right now).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runSafariCleanup(self.safariBookmarks.previewLeakedRootFolderCleanup(), key: Self.leakedRootCleanupKey)
        }
        startSafariBookmarkMonitor()
        // Do not put potentially large file-system cleanup on the initialization
        // path. The app must become launchable before maintenance begins.
        DispatchQueue.main.async { [weak self] in
            self?.removeLegacyPayloadLogs()
            self?.pruneManagedSyncLogs()
        }
    }

    func bookmarkFolderMissing(_ browser: Browser, folder: String?) -> Bool {
        guard let folder, !folder.isEmpty else { return false }
        let wasReportedMissing = BookmarkFolderPath.canonicalized(missingBookmarkFolders[browser.rawValue]) == BookmarkFolderPath.canonicalized(folder)
        // Other browsers are read through cached snapshots. A newer failure
        // reported by their extension takes precedence over that cache.
        if browser != .safari, wasReportedMissing { return true }
        let tree = bookmarkTreeSnapshot(for: browser)
        guard !tree.isEmpty else {
            return wasReportedMissing
        }
        return !BookmarkTreeMerger.folderExists(tree: tree, folderPath: folder)
    }

    func bookmarkFolderKnownExists(_ browser: Browser, folder: String?) -> Bool {
        guard let folder, !folder.isEmpty else { return true }
        let tree = bookmarkTreeSnapshot(for: browser)
        guard !tree.isEmpty else { return false }
        return BookmarkTreeMerger.folderExists(tree: tree, folderPath: folder)
    }

    private func bookmarkTreeSnapshot(for browser: Browser) -> [Bookmark] {
        if browser == .safari {
            // Safari's diff snapshot contains the selected folder's flattened
            // contents, not the folder itself. Validate against the live tree,
            // just like the folder picker, rather than that scoped snapshot.
            return safariBookmarks.readBookmarks().map {
                Bookmark(id: $0.id, title: $0.title, url: $0.url.flatMap { $0 }, parentId: $0.parentId, isFolder: $0.isFolder, sortIndex: $0.sortIndex, inBookmarksBar: $0.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
            }
        }
        return backupService?.getSnapshot(sourceBrowser: browser.rawValue) ?? []
    }

    private func markMissingBookmarkFolder(_ browser: Browser, folder: String) {
        missingBookmarkFolders[browser.rawValue] = folder
        log("Bookmark sync skipped for \(browser.displayName): selected folder not found")
        AppState.shared.notificationService.notifyBookmarkSyncFailed(browser: browser, folder: folder)
    }

    private func clearMissingBookmarkFolder(_ browser: Browser) {
        missingBookmarkFolders.removeValue(forKey: browser.rawValue)
    }

    func folderAdjustedBookmarksForSource(_ bookmarks: [Bookmark], browser: Browser) -> [Bookmark]? {
        let folder = settings.bookmarkFolder(for: browser)
        if folder == nil || folder?.isEmpty == true {
            clearMissingBookmarkFolder(browser)
            // Keep canonical system-root parent IDs intact. A root-to-root sync
            // maps these roots by role (bar/other/mobile), never by title.
            return bookmarks
        }
        if let folder, !folder.isEmpty, !BookmarkTreeMerger.folderExists(tree: bookmarks, folderPath: folder) {
            markMissingBookmarkFolder(browser, folder: folder)
            return nil
        }
        clearMissingBookmarkFolder(browser)
        // The chosen source folder is flattened into the receiver's selected
        // target. Parent 2 represents that portable target-root boundary;
        // parent 1 specifically means the receiver's native bookmarks bar.
        return BookmarkTreeMerger.extractExistingSubtreeAsRoot(
            sourceTree: bookmarks,
            folderPath: folder,
            portableParentId: "2"
        )
    }

    /// A system root can only become an ordinary named folder when the receiver
    /// is a user-selected non-root folder. Root receivers must retain the
    /// canonical parent IDs so their native system roots are mapped by role.
    func bookmarksPreparedForTarget(_ bookmarks: [Bookmark], sourceBrowser: Browser, targetBrowser: Browser) -> [Bookmark] {
        guard settings.bookmarkFolder(for: sourceBrowser)?.isEmpty != false,
              settings.bookmarkFolder(for: targetBrowser)?.isEmpty == false else {
            return bookmarks
        }
        return BookmarkTreeMerger.wrappingSystemRootsForNonRootTarget(
            sourceTree: bookmarks,
            sourceBrowser: sourceBrowser
        )
    }

    /// Backups deliberately retain the selected folder itself. Sync payloads
    /// flatten that folder to a portable root, but doing so in a backup loses
    /// browser-owned roots such as Chrome's Bookmarks Bar.
    private func backupBookmarksForSource(_ bookmarks: [Bookmark], browser: Browser) -> [Bookmark]? {
        let archivalTree = addingMissingSystemRootsToBackup(bookmarks, browser: browser)
        let folder = settings.bookmarkFolder(for: browser)
        if let folder, !folder.isEmpty, !BookmarkTreeMerger.folderExists(tree: archivalTree, folderPath: folder) {
            markMissingBookmarkFolder(browser, folder: folder)
            return nil
        }
        clearMissingBookmarkFolder(browser)
        return BookmarkTreeMerger.extractExistingSubtreeWithAncestors(sourceTree: archivalTree, folderPath: folder)
    }

    /// Chrome-family sync snapshots intentionally omit their immutable root
    /// folders, while retaining the canonical parent IDs 1/2/3 on children.
    /// Rebuild those omitted nodes only for the archive so the displayed and
    /// restorable tree includes Bookmarks Bar and the other browser roots.
    private func addingMissingSystemRootsToBackup(_ bookmarks: [Bookmark], browser: Browser) -> [Bookmark] {
        let roots: [(id: String, title: String, inBookmarksBar: Bool)] = [
            ("1", String(localized: "Bookmarks Bar"), true),
            ("2", String(localized: "Other Bookmarks"), false),
            ("3", String(localized: "Mobile Bookmarks"), false)
        ]
        var result = bookmarks
        let existingIDs = Set(bookmarks.map(\.id))
        let parentIDs = Set(bookmarks.compactMap(\.parentId))
        for root in roots where parentIDs.contains(root.id) && !existingIDs.contains(root.id) {
            result.append(
                Bookmark(
                    id: root.id,
                    title: root.title,
                    url: nil,
                    parentId: "0",
                    isFolder: true,
                    sortIndex: nil,
                    inBookmarksBar: root.inBookmarksBar,
                    dateAdded: nil,
                    sourceBrowser: browser
                )
            )
        }
        return result
    }

    /// Browser workers report create/update/move activity immediately. Keep
    /// the restartable quiet-period timer in the long-lived native app.
    private func handleIncomingBookmarkChangeSignal(clientId: String) {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        guard let browser = Browser(rawValue: browserId),
              settings.bookmarkParticipatingBrowsers.contains(browser),
              settings.bookmarkSyncStrategy != .oneWay || settings.bookmarkSourceBrowser == browser else {
            log("Ignored bookmark activity from [\(clientId)]: this browser is not the configured one-way source.")
            return
        }
        let isPro = AppState.shared.purchaseService.isProUnlocked
        guard (isPro && settings.bookmarkAutoSync && settings.enabledCategories.contains(.bookmarks)) || isSyncing else {
            log("Observed bookmark activity from [\(clientId)], but automatic bookmark sync is off or unavailable.")
            return
        }

        bookmarkChangeDebounceTasks[clientId]?.cancel()
        bookmarkChangeDebounceTasks[clientId] = Task { [weak self] in
            // Browsers commonly finish a bookmark edit by asynchronously
            // rewriting sibling indexes and metadata. Wait for a real quiet
            // period so a single create does not produce a half-finished tree
            // and an immediate review window.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.bookmarkChangeDebounceTasks[clientId] = nil
                let request = WSMessage(type: .sync, site: "*", category: "bookmarks", payload: nil, messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
                self.daemon?.broadcast(request, participatingBrowsers: [browser])
                self.log("Bookmark changes from [\(clientId)] were quiet for 10 seconds; requested a fresh snapshot.")
            }
        }
    }

    private var bookmarkSettingsFingerprint: String {
        let s = settings
        return [
            String(describing: s.bookmarkSyncStrategy),
            s.bookmarkSourceBrowser.rawValue,
            s.bookmarkParticipatingBrowsers.map(\.rawValue).sorted().joined(separator: ","),
            s.enabledCategories.contains(.bookmarks) ? "on" : "off",
            Browser.allCases.map { "\($0.rawValue)=\(s.bookmarkFolder(for: $0) ?? "")" }.joined(separator: ","),
            s.bookmarkSafeMode ? "safe" : "threshold"
        ].joined(separator: "|")
    }

    /// The held change for a browser, provided it still matches the current
    /// bookmark sync settings; a stale one is discarded here.
    private func validPendingSafariWrite(for clientId: String) -> PendingSafariWrite? {
        guard let write = pendingSafariWrites[clientId] else { return nil }
        guard write.settingsFingerprint == bookmarkSettingsFingerprint else {
            clearPendingSafariWrite(for: clientId)
            log("Discarded the held Safari bookmark change from [\(clientId)] because bookmark sync settings changed.")
            return nil
        }
        return write
    }

    /// Called after bookmark sync settings change.
    func discardStalePendingSafariWrites() {
        if let session = bookmarkSyncSession, session.settingsFingerprint != bookmarkSettingsFingerprint,
           session.phase == .collecting || session.phase == .reviewing {
            discardBookmarkSyncSession(reason: "bookmark sync settings changed")
        }
        for key in pendingBrowserWrites.keys.sorted() {
            _ = validPendingBrowserWrite(key: key)
        }
        let pendingBefore = pendingSafariWrites.count
        for clientId in pendingSafariWrites.keys.sorted() {
            _ = validPendingSafariWrite(for: clientId)
        }
        if pendingSafariWrites.count < pendingBefore {
            // Changes deferred during the review are recomputed by a session.
            scheduleBookmarkSyncSession()
        }
        let fingerprint = bookmarkSettingsFingerprint
        approvedSafariWriteSignatures = approvedSafariWriteSignatures.filter { $0.value.settingsFingerprint == fingerprint }
        let currentSuffix = rejectionKey("")
        let validRejections = rejectedSafariWriteSignatures.filter { $0.value.hasSuffix(currentSuffix) }
        if validRejections.count != rejectedSafariWriteSignatures.count {
            rejectedSafariWriteSignatures = validRejections
            log("Cleared decisions to keep Safari unchanged because bookmark sync settings changed.")
        }
    }

    /// While a two-way change from a browser awaits review, Safari's tree is
    /// not pushed to it: that would silently undo the change being reviewed,
    /// and a later "Apply" would swap the two layouts.
    private func isSafariPushDeferred(to clientId: String) -> Bool {
        settings.bookmarkSyncStrategy == .twoWayMerge
            && (validPendingSafariWrite(for: clientId) != nil || validPendingSafariWrite(for: "rm:" + clientId) != nil)
    }

    /// Holds a large Safari write for review. Returns true if it was written
    /// right away because the user had already approved exactly this change.
    @discardableResult
    private func holdLargeSafariWrite(_ write: PendingSafariWrite, clientId: String) -> Bool {
        var write = write
        write.settingsFingerprint = bookmarkSettingsFingerprint
        let impact = write.held.impact
        guard impact.changeCount > 0 else {
            clearPendingSafariWrite(for: clientId)
            AppState.shared.notificationService.removeBookmarkReviewNotification(clientId: clientId)
            log("Discarded a zero-change Safari review from [\(clientId)] before queuing or notifying.")
            return true
        }
        guard hasReviewableChanges(write.held.preview) else {
            // A count without matching preview rows is not an approval
            // contract. Fail closed rather than showing an empty review card.
            clearPendingSafariWrite(for: clientId)
            requestFreshBookmarkSnapshot(for: clientId)
            log("Rejected an inconsistent Safari bookmark review from [\(clientId)]: reported changes had no reviewable operations. Safari was not written.")
            return true
        }
        if let approval = approvedSafariWriteSignatures.removeValue(forKey: clientId),
           approval.signature == impact.signature,
           approval.settingsFingerprint == write.settingsFingerprint,
           approval.expires > Date() {
            clearPendingSafariWrite(for: clientId)
            if let count = safariBookmarks.commitHeldWrite(write.held, from: write.sourceName) {
                lastNetworkSyncTime = Date()
                log("Wrote the large Safari bookmark change from [\(clientId)] that the user approved.")
                finishApprovedSafariWrite(count)
                return true
            }
        }
        // A refused removal/move/rewrite stays refused even if the source
        // browser has since added bookmarks (additions alone are not compared).
        // A manual Sync Now clears refusals and asks again.
        if rejectedSafariWriteSignatures[clientId] == rejectionKey(impact.destructiveSignature) {
            clearPendingSafariWrite(for: clientId)
            if loggedRejectedSafariWriteSkips.insert(clientId + impact.destructiveSignature).inserted {
                log("Skipped a large Safari bookmark change from [\(clientId)] that the user already chose not to apply.")
            }
            return false
        }
        let previous = validPendingSafariWrite(for: clientId)
        // Always keep the latest computation: it was made against Safari's
        // current file, so it is the one that can still be committed as is.
        pendingSafariWrites[clientId] = write
        let reviewWindow = BookmarkChangeReviewWindowController.shared
        if previous?.held.impact.destructiveSignature == impact.destructiveSignature {
            // Same destructive change, perhaps with different additions: refresh
            // an open review in place, but never re-interrupt the user.
            if previous?.held.impact.signature != impact.signature, let presented = reviewWindow.presentedClientId {
                presentPendingSafariWrite(from: presented, activate: false)
            }
            return false
        }
        log("Blocked a large Safari bookmark change from [\(clientId)]: \(impact.removed) removed, \(impact.moved) moved and \(impact.modified) modified of \(impact.total) existing items. Nothing was written — asking user to confirm.")
        // There is one aggregate review window. A newly held plan is appended
        // to it without stealing focus.
        if let presented = reviewWindow.presentedClientId {
            presentPendingSafariWrite(from: presented, activate: false)
            return false
        }
        if reviewWindow.presentedClientId == nil {
            presentPendingSafariWrite(from: clientId)
        }
        AppState.shared.notificationService.notifyBookmarkChangesAwaitingReview(
            source: Self.displayName(forClient: clientId),
            target: "Safari",
            clientId: clientId,
            added: impact.added,
            removed: impact.removed,
            moved: impact.moved,
            modified: impact.modified,
            isLarge: impact.requiresConfirmation
        )
        return false
    }

    /// A later write from the same browser went through (or was rejected), so
    /// an older held change, its approval and its window no longer describe
    /// anything real.
    private func clearPendingSafariWrite(for clientId: String) {
        approvedSafariWriteSignatures.removeValue(forKey: clientId)
        AppState.shared.notificationService.removeBookmarkReviewNotification(clientId: clientId)
        guard pendingSafariWrites.removeValue(forKey: clientId) != nil else { return }
        BookmarkChangeReviewWindowController.shared.dismiss(ifPresenting: clientId)
    }

    /// Opens the before/after review for a held write (notification, menu bar).
    func presentPendingBookmarkReview(preferredKey: String? = nil) {
        if bookmarkSyncSession?.phase == .reviewing,
           preferredKey == nil || preferredKey == Self.bookmarkSessionReviewKey
            || BookmarkChangeReviewWindowController.shared.presentedClientId == nil {
            presentBookmarkSyncSessionReview()
            return
        }
        let candidates = [preferredKey, BookmarkChangeReviewWindowController.shared.presentedClientId]
            .compactMap { $0 }
        for key in candidates {
            if key.hasPrefix("to:"), validPendingBrowserWrite(key: key) != nil {
                presentPendingBrowserWrite(key: key)
                return
            }
            if validPendingSafariWrite(for: key) != nil {
                presentPendingSafariWrite(from: key)
                return
            }
        }
        for key in pendingSafariWrites.keys.sorted() where validPendingSafariWrite(for: key) != nil {
            presentPendingSafariWrite(from: key)
            return
        }
        for key in pendingBrowserWrites.keys.sorted() where validPendingBrowserWrite(key: key) != nil {
            presentPendingBrowserWrite(key: key)
            return
        }
        log("Review notification was opened after its pending bookmark plan had already expired or been resolved.")
    }

    func hasPendingBookmarkReview(key: String) -> Bool {
        if key == Self.bookmarkSessionReviewKey { return bookmarkSyncSession?.phase == .reviewing }
        return key.hasPrefix("to:") ? pendingBrowserWrites[key] != nil : pendingSafariWrites[key] != nil
    }

    func presentPendingSafariWrite(from clientId: String, activate: Bool = true) {
        // A review is a frozen approval contract.  Do not replace its SwiftUI
        // tree while the user is ticking rows: later plans wait for the next
        // review instead of resetting selection or changing row order.
        guard BookmarkChangeReviewWindowController.shared.presentedClientId == nil else { return }
        if clientId.hasPrefix("to:") {
            presentPendingBrowserWrite(key: clientId, activate: activate)
            return
        }
        guard let write = validPendingSafariWrite(for: clientId) else {
            presentNextPendingSafariWrite()
            return
        }
        let reviewed = write.held.impact
        guard reviewed.changeCount > 0 else {
            log("Discarded an empty bookmark review from [\(clientId)]; no destination changes were proposed.")
            clearPendingSafariWrite(for: clientId)
            presentNextPendingSafariWrite()
            return
        }
        guard hasReviewableChanges(write.held.preview) else {
            clearPendingSafariWrite(for: clientId)
            requestFreshBookmarkSnapshot(for: clientId)
            log("Dismissed an inconsistent Safari review from [\(clientId)]; it had no visible operations and Safari was not written.")
            presentNextPendingSafariWrite()
            return
        }
        BookmarkChangeReviewWindowController.shared.present(
            clientId: clientId,
            reviewRoutes: pendingReviewRoutes,
            activate: activate,
            onApplySelected: { [weak self] selection, conflicts, _ in self?.applySelectedPendingBookmarkReviews(selection, conflictResolutions: conflicts) },
            onCancel: { [weak self] in self?.cancelPendingBookmarkReview() }
        )
    }

    private func presentNextPendingSafariWrite() {
        guard !isResolvingReviewBatch, BookmarkChangeReviewWindowController.shared.presentedClientId == nil else { return }
        if pendingBookmarkConflictResolution != nil {
            presentPendingBookmarkConflictReview()
            return
        }
        for next in pendingSafariWrites.keys.sorted() where validPendingSafariWrite(for: next) != nil {
            presentPendingSafariWrite(from: next)
            return
        }
        for next in pendingBrowserWrites.keys.sorted() where validPendingBrowserWrite(key: next) != nil {
            presentPendingBrowserWrite(key: next)
            return
        }
    }

    /// Every held target is reviewed independently. A decision for one browser
    /// never approves, rejects, or rewrites another target.
    private var pendingReviewRoutes: [BookmarkReviewRoute] {
        let safariRoutes: [BookmarkReviewRoute] = pendingSafariWrites.compactMap { entry in
            let (key, write) = entry
            guard write.held.impact.changeCount > 0, hasReviewableChanges(write.held.preview) else { return nil }
            return BookmarkReviewRoute(id: key, source: Self.displayName(forClient: key), target: "Safari", impact: write.held.impact, preview: write.held.preview)
        }
        let browserRoutes: [BookmarkReviewRoute] = pendingBrowserWrites.compactMap { entry in
            let (key, write) = entry
            guard write.impact.changeCount > 0, hasReviewableChanges(write.preview) else { return nil }
            return BookmarkReviewRoute(
                id: key,
                source: write.message.browser.map(Self.displayName(forClient:)) ?? "BrowSync",
                target: Self.displayName(forClient: key),
                impact: write.impact,
                preview: write.preview
            )
        }
        let conflictRoutes: [BookmarkReviewRoute] = pendingBookmarkConflictResolution.map { pending in
            [BookmarkReviewRoute(
                id: pendingBookmarkConflictRouteID,
                source: pending.input.message.browser.map(Self.displayName(forClient:)) ?? "BrowSync",
                target: Self.displayName(forClient: pending.input.clientId),
                impact: .init(added: 0, removed: 0, moved: 0, modified: 0, total: 0, signature: "conflicts", destructiveSignature: ""),
                preview: .init(before: [], after: []),
                conflicts: pending.conflicts
            )]
        } ?? []
        let propagationRoutes: [BookmarkReviewRoute] = pendingBookmarkConflictResolution.map { pending in
            pending.propagationTargets.compactMap { browser in
                guard let client = daemon?.connectedClients.first(where: { $0.browser == browser }),
                      mayWriteBookmarks(to: client) else { return nil }
                let nodes = pending.conflicts.map { conflict in
                    BookmarkReviewNode(
                        id: "\(conflict.id)|\(browser.rawValue)",
                        title: conflict.source.title,
                        url: conflict.source.url.flatMap { $0 },
                        isFolder: conflict.source.isFolder,
                        change: .added,
                        children: [],
                        containingPath: "/"
                    )
                }
                guard !nodes.isEmpty else { return nil }
                return BookmarkReviewRoute(
                    id: conflictPropagationRouteID(browser),
                    source: pending.input.message.browser.map(Self.displayName(forClient:)) ?? "BrowSync",
                    target: browser.displayName,
                    impact: .init(added: nodes.count, removed: 0, moved: 0, modified: 0, total: nodes.count,
                                  signature: "conflict-propagation-\(browser.rawValue)", destructiveSignature: ""),
                    preview: .init(before: [], after: nodes)
                )
            }
        } ?? []
        return (safariRoutes + browserRoutes + conflictRoutes + propagationRoutes).sorted {
            if $0.source != $1.source { return $0.source.localizedStandardCompare($1.source) == .orderedAscending }
            return $0.target.localizedStandardCompare($1.target) == .orderedAscending
        }
    }

    /// A review is valid only when it has concrete, visible operations. A
    /// transport count alone is not sufficient to authorize a write.
    private func hasReviewableChanges(_ preview: BookmarkChangePreview) -> Bool {
        // Same rule the window uses to build its rows.
        BookmarkChangeReviewView.visibleRowCount(for: preview) > 0
    }

    private var isResolvingReviewBatch = false

    private var pendingBookmarkConflictRouteID: String {
        guard let pending = pendingBookmarkConflictResolution else { return "conflict" }
        return "conflict:\(pending.input.clientId):\(pending.input.message.messageId ?? "")"
    }

    private func conflictPropagationRouteID(_ browser: Browser) -> String {
        "\(pendingBookmarkConflictRouteID):to:\(browser.rawValue)"
    }

    private func applySelectedPendingBookmarkReviews(
        _ selection: [String: Set<String>],
        conflictResolutions: [String: [String: BookmarkConflictResolution]]
    ) {
        let safari = pendingSafariWrites.map { ($0.key, $0.value.held.impact.signature) }
        let browsers = pendingBrowserWrites.map { ($0.key, $0.value.impact.signature) }
        isResolvingReviewBatch = true
        safari.forEach {
            if let ids = selection[$0.0], !ids.isEmpty { applyPendingSafariWrite(from: $0.0, reviewedSignature: $0.1, selectedNodeIds: ids) }
            else { clearPendingSafariWrite(for: $0.0) }
        }
        browsers.forEach {
            if let ids = selection[$0.0], !ids.isEmpty { applyPendingBrowserWrite(key: $0.0, reviewedSignature: $0.1, selectedNodeIds: ids) }
            else { clearPendingBrowserWrite(key: $0.0) }
        }
        if let resolutions = conflictResolutions[pendingBookmarkConflictRouteID] {
            let selectedPropagationTargets = Set(
                pendingBookmarkConflictResolution?.propagationTargets.filter {
                    !(selection[conflictPropagationRouteID($0)] ?? []).isEmpty
                } ?? []
            )
            applyPendingBookmarkConflictResolutions(resolutions, propagationTargets: selectedPropagationTargets)
        }
        isResolvingReviewBatch = false
        presentNextPendingSafariWrite()
    }

    private func cancelPendingBookmarkReview() {
        let safari = Array(pendingSafariWrites.keys)
        let browsers = Array(pendingBrowserWrites.keys)
        isResolvingReviewBatch = true
        safari.forEach { clearPendingSafariWrite(for: $0) }
        browsers.forEach { clearPendingBrowserWrite(key: $0) }
        pendingBookmarkConflictResolution = nil
        isResolvingReviewBatch = false
        cancelActiveManualSyncIfNeeded()
        log("Cancelled the current bookmark sync review. No rejection was remembered; future syncs will recompute all differences.")
    }

    private func cancelActiveManualSyncIfNeeded() {
        guard activeManualSyncID != nil else { return }
        activeManualSyncID = nil
        lastManualSyncWasCancelled = true
        ignoreBookmarkObservationsUntil = Date().addingTimeInterval(12)
        isSyncing = false
        log("Cancelled the active manual bookmark sync; late bookmark observations are ignored for this request window.")
    }

    private func manualSyncIsActive(_ id: UUID) -> Bool {
        isSyncing && activeManualSyncID == id
    }

    // MARK: Large writes into other browsers

    func recordSentBookmarkMessage(_ message: WSMessage, to clientId: String) {
        guard case .bookmarks = message.payload else { return }
        lastBookmarkMessageByClient[Self.messageRecordKey(clientId, message.category)] = message
    }

    /// Takes ownership before DaemonServer dispatches any browser bookmark
    /// mutation. The extension receives only a read-only context request.
    func stageBrowserBookmarkMutation(_ message: WSMessage, to client: ConnectedClient) -> Bool {
        let explicitRestore = message.isExplicitDeletedBookmarkRestore == true || message.isExplicitBookmarkRestore == true
        guard client.browser != .safari,
              case .bookmarks = message.payload,
              BookmarkWritePolicy.allowsWrite(to: client.browser, settings: settings, explicitRestore: explicitRestore) else { return true }
        let requestId = UUID().uuidString
        pendingNativePlanInputs[requestId] = PendingNativePlanInput(message: message, clientId: client.id, browser: client.browser, conflictOnly: false)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nativePlanContextTimeout)
            guard let self, self.pendingNativePlanInputs.removeValue(forKey: requestId) != nil else { return }
            self.log("Discarded bookmark planning request for [\(client.id)] because the extension did not return a current tree in time. Nothing was written and the request will not be retried automatically.")
        }
        let request = WSMessage(type: .pull, site: requestId, category: "bookmark_plan_context",
                                payload: .raw(["requestId": AnyCodable(requestId),
                                               "targetFolder": AnyCodable(message.targetBookmarkFolder ?? NSNull())]),
                                messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
        daemon?.sendBookmarkControlMessage(request, to: client)
        log("Requested native bookmark tree from [\(client.id)] before planning mutation in the app.")
        return true
    }

    /// Removal batches and full syncs are recorded apart, so neither
    /// supersedes the other.
    private static func messageRecordKey(_ clientId: String, _ category: String?) -> String {
        category == removalBatchCategory ? "rm:" + clientId : clientId
    }

    private func validPendingBrowserWrite(key: String) -> PendingBrowserWrite? {
        guard let write = pendingBrowserWrites[key] else { return nil }
        guard write.settingsFingerprint == bookmarkSettingsFingerprint else {
            clearPendingBrowserWrite(key: key)
            log("Discarded the held bookmark change into [\(Self.reviewTarget(key))] because bookmark sync settings changed.")
            return nil
        }
        return write
    }

    private func clearPendingBrowserWrite(key: String) {
        AppState.shared.notificationService.removeBookmarkReviewNotification(clientId: key)
        guard pendingBrowserWrites.removeValue(forKey: key) != nil else { return }
        BookmarkChangeReviewWindowController.shared.dismiss(ifPresenting: key)
    }

    /// A browser's extension held an incoming sync because its dry run would
    /// remove, move or rewrite many of that browser's bookmarks.
    private func handleHeldBrowserWrite(_ message: WSMessage, clientId: String) {
        guard case .raw(let raw) = message.payload,
              let signature = raw["signature"]?.value as? String,
              let destructive = raw["destructiveSignature"]?.value as? String else { return }
        let reportedMessageId = raw["messageId"]?.value as? String
        // Only the latest message of its kind sent to that browser can still be
        // approved; a report about an older one is superseded by the newer one.
        let removalBatch = lastBookmarkMessageByClient["rm:" + clientId]
        let isRemovalBatch = reportedMessageId != nil && removalBatch?.messageId == reportedMessageId
        let key = (isRemovalBatch ? "to:rm:" : "to:") + clientId
        guard let sent = isRemovalBatch ? removalBatch : lastBookmarkMessageByClient[clientId],
              reportedMessageId == nil || reportedMessageId == sent.messageId else {
            log("Ignored a held bookmark change from [\(clientId)] for a superseded sync.")
            return
        }
        let count = { (field: String) in (raw[field]?.value as? Int) ?? 0 }
        let impact = SafariBookmarkService.WriteImpact(
            added: count("added"), removed: count("removed"), moved: count("moved"), modified: count("modified"), total: count("total"),
            signature: signature, destructiveSignature: destructive
        )
        guard impact.changeCount > 0 else {
            clearPendingBrowserWrite(key: key)
            log("Discarded a zero-change browser review into [\(clientId)] before queuing or notifying.")
            return
        }
        if rejectedSafariWriteSignatures[key] == rejectionKey(destructive) {
            clearPendingBrowserWrite(key: key)
            if loggedRejectedSafariWriteSkips.insert(key + destructive).inserted {
                log("Skipped a large bookmark change into [\(clientId)] that the user already chose not to apply.")
            }
            return
        }
        let preview = BookmarkChangePreview(before: reviewNodes(raw["before"]?.value), after: reviewNodes(raw["after"]?.value))
        guard hasReviewableChanges(preview) else {
            log("Rejected an inconsistent held bookmark plan into [\(clientId)]: its reported changes had no reviewable operations. Nothing was written; requesting a fresh snapshot.")
            requestFreshBookmarkSnapshot(for: clientId)
            return
        }
        let previous = validPendingBrowserWrite(key: key)
        pendingBrowserWrites[key] = PendingBrowserWrite(message: sent, impact: impact, preview: preview, settingsFingerprint: bookmarkSettingsFingerprint)
        let reviewWindow = BookmarkChangeReviewWindowController.shared
        if previous?.impact.destructiveSignature == destructive {
            if previous?.impact.signature != signature, let presented = reviewWindow.presentedClientId {
                presentPendingSafariWrite(from: presented, activate: false)
            }
            return
        }
        log("Blocked a large bookmark change into [\(clientId)]: \(impact.removed) removed, \(impact.moved) moved and \(impact.modified) modified of \(impact.total) existing items. Nothing was written — asking user to confirm.")
        if let presented = reviewWindow.presentedClientId {
            presentPendingSafariWrite(from: presented, activate: false)
            return
        }
        if reviewWindow.presentedClientId == nil {
            presentPendingBrowserWrite(key: key)
        }
        AppState.shared.notificationService.notifyBookmarkChangesAwaitingReview(
            source: sent.browser.map(Self.displayName(forClient:)) ?? "BrowSync",
            target: Self.displayName(forClient: clientId),
            clientId: key,
            added: impact.added,
            removed: impact.removed,
            moved: impact.moved,
            modified: impact.modified,
            isLarge: impact.requiresConfirmation
        )
    }

    /// The browser wrote an incoming sync (small, or the approved plan).
    private func handleBrowserWriteResult(_ message: WSMessage, clientId: String) {
        guard case .raw(let raw) = message.payload else { return }
        let messageId = raw["messageId"]?.value as? String
        if let messageId, acceptRestoreWriteResult(raw, messageId: messageId, clientId: clientId) { return }
        if let messageId, acceptSessionBookmarkWriteResult(raw, messageId: messageId, clientId: clientId) { return }
        if let messageId, let operations = dispatchedNativePlans.removeValue(forKey: messageId) {
            guard (raw["applied"]?.value as? Bool) == true,
                  (raw["verified"]?.value as? Bool) == true,
                  verifyNativeOperationResults(raw["operationResults"]?.value, operations: operations) else {
                log("App rejected the bookmark write result from [\(clientId)]: execution failed or independently verified results did not match the approved plan.")
                let key = "to:" + clientId
                clearPendingBrowserWrite(key: key)
                return
            }
        }
        let isRemovalBatch = messageId != nil && lastBookmarkMessageByClient["rm:" + clientId]?.messageId == messageId
        let isFullSync = messageId == nil || lastBookmarkMessageByClient[clientId]?.messageId == messageId
        // A result for a superseded message settles nothing.
        guard isRemovalBatch || isFullSync else { return }
        if let messageId,
           let restore = pendingDeletedRestoreByMessageId.removeValue(forKey: messageId),
           raw["applied"]?.value as? Bool == true,
           raw["verified"]?.value as? Bool == true {
            backupService?.markDeletedBookmarksRestored(ids: restore.ids, from: restore.browser)
        }
        // A result only settles the review of the same message.
        let key = (isRemovalBatch ? "to:rm:" : "to:") + clientId
        if let pending = pendingBrowserWrites[key], let messageId, pending.message.messageId != messageId {
            return
        }
        clearPendingBrowserWrite(key: key)
        if ((raw["writes"]?.value as? Int) ?? 0) > 0, rejectedSafariWriteSignatures.removeValue(forKey: key) != nil {
            log("Bookmark sync into [\(clientId)] is back in line; the earlier decision to keep it unchanged no longer applies.")
        }
    }

    private func verifyNativeOperationResults(_ value: Any?, operations: [BookmarkMutationOperation]) -> Bool {
        let rawItems: [Any]
        if let value = value as? [Any] { rawItems = value }
        else if let value = value as? [AnyCodable] { rawItems = value.map(\.value) }
        else { return false }
        func dictionary(_ value: Any) -> [String: Any] {
            if let value = value as? [String: Any] { return value }
            if let value = value as? [String: AnyCodable] { return value.mapValues(\.value) }
            return [:]
        }
        let results = Dictionary(rawItems.compactMap { item -> (String, [String: Any])? in
            let result = dictionary(item)
            guard let id = result["id"] as? String, let type = result["type"] as? String else { return nil }
            return (type + "|" + id, result)
        }, uniquingKeysWith: { _, last in last })
        guard results.count == Set(operations.map { $0.kind.rawValue + "|" + $0.id }).count else { return false }
        let actualIds = Dictionary(operations.compactMap { operation -> (String, String)? in
            guard operation.kind == .create,
                  let actualId = results[operation.kind.rawValue + "|" + operation.id]?["actualId"] as? String else { return nil }
            return (operation.id, actualId)
        }, uniquingKeysWith: { first, _ in first })
        func canonicalURL(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return URL(string: value)?.absoluteURL.absoluteString ?? value
        }
        for operation in operations {
            guard let result = results[operation.kind.rawValue + "|" + operation.id] else { return false }
            let exists = result["exists"] as? Bool ?? false
            if operation.kind == .removeTree {
                if exists { return false }
                continue
            }
            guard exists else { return false }
            if let title = operation.title, result["title"] as? String != title { return false }
            if let url = operation.url,
               canonicalURL(result["url"] as? String) != canonicalURL(url) { return false }
            if operation.kind == .create || operation.kind == .move, let parent = operation.parentId {
                let expectedParent = actualIds[parent] ?? parent
                if result["parentId"] as? String != expectedParent { return false }
            }
            if operation.kind == .create || operation.kind == .move,
               let index = operation.index, result["index"] as? Int != index { return false }
        }
        return true
    }

    private func reviewNodes(_ value: Any?) -> [BookmarkReviewNode] {
        (value as? [Any] ?? []).compactMap { item in
            guard let node = item as? [String: Any] else { return nil }
            let change: BookmarkReviewNode.Change
            switch node["change"] as? String {
            case "added": change = .added
            case "removed": change = .removed
            case "moved": change = .moved
            case "modified": change = .modified
            default: change = .unchanged
            }
            return BookmarkReviewNode(
                id: node["id"] as? String ?? UUID().uuidString,
                title: node["title"] as? String ?? "",
                url: node["url"] as? String,
                isFolder: node["isFolder"] as? Bool ?? true,
                change: change,
                children: reviewNodes(node["children"])
            )
        }
    }

    private func presentPendingBrowserWrite(key: String, activate: Bool = true) {
        // See `presentPendingSafariWrite`: never mutate an open review.
        guard BookmarkChangeReviewWindowController.shared.presentedClientId == nil else { return }
        guard let write = validPendingBrowserWrite(key: key) else {
            presentNextPendingSafariWrite()
            return
        }
        let reviewed = write.impact
        guard reviewed.changeCount > 0 else {
            log("Discarded an empty bookmark review into [\(Self.reviewTarget(key))]; no destination changes were proposed.")
            clearPendingBrowserWrite(key: key)
            presentNextPendingSafariWrite()
            return
        }
        guard hasReviewableChanges(write.preview) else {
            clearPendingBrowserWrite(key: key)
            requestFreshBookmarkSnapshot(for: Self.reviewTarget(key))
            log("Dismissed an inconsistent browser review into [\(Self.reviewTarget(key))]; it had no visible operations and nothing was written.")
            presentNextPendingSafariWrite()
            return
        }
        BookmarkChangeReviewWindowController.shared.present(
            clientId: key,
            reviewRoutes: pendingReviewRoutes,
            activate: activate,
            onApplySelected: { [weak self] selection, conflicts, _ in self?.applySelectedPendingBookmarkReviews(selection, conflictResolutions: conflicts) },
            onCancel: { [weak self] in self?.cancelPendingBookmarkReview() }
        )
    }

    private func applyPendingBrowserWrite(key: String, reviewedSignature: String, selectedNodeIds: Set<String>? = nil) {
        guard let write = validPendingBrowserWrite(key: key) else {
            log("The reviewed bookmark change into [\(Self.reviewTarget(key))] is no longer pending; nothing was sent.")
            presentNextPendingSafariWrite()
            return
        }
        guard write.impact.signature == reviewedSignature else {
            presentPendingBrowserWrite(key: key)
            return
        }
        let clientId = Self.reviewTarget(key)
        clearPendingBrowserWrite(key: key)
        // The extension recomputes the plan and writes only if it is still
        // exactly the reviewed one; otherwise it reports a new review.
        var message = write.message
        if message.category == "bookmark_apply_plan", case .raw(var raw)? = message.payload {
            var selected = selectedNodeIds ?? []
            let creates = Dictionary(uniqueKeysWithValues: (write.nativeOperations ?? [])
                .filter { $0.kind == .create }.map { ($0.id, $0) })
            for id in Array(selected) {
                var parent = creates[id]?.parentId
                while let current = parent, let create = creates[current] {
                    selected.insert(current)
                    parent = create.parentId
                }
            }
            raw["selectedNodeIds"] = AnyCodable(Array(selected))
            message.payload = .raw(raw)
            if let messageId = message.messageId {
                dispatchedNativePlans[messageId] = (write.nativeOperations ?? []).filter { selected.contains($0.id) }
            }
        }
        if let latest = lastBookmarkMessageByClient[Self.messageRecordKey(clientId, message.category)], latest.messageId != message.messageId {
            // A newer sync went out meanwhile: it supersedes the reviewed one.
            // Send it unapproved; if it is large too, it is reviewed itself.
            message = latest
        } else if message.category != "bookmark_apply_plan" {
            message.approvedPlanSignature = reviewedSignature
            message.approvedBookmarkNodeIds = selectedNodeIds.map(Array.init)
        }
        if let client = daemon?.connectedClients.first(where: { $0.id == clientId }) {
            daemon?.sendWSMessage(message, to: client)
            log("User approved a large bookmark change into [\(clientId)] (\(write.impact.removed) removed, \(write.impact.moved) moved, \(write.impact.modified) modified).")
        } else {
            log("User approved a large bookmark change into [\(clientId)], but it is not connected; it will be reviewed again on its next sync.")
        }
        presentNextPendingSafariWrite()
    }

    private func rejectPendingBrowserWrite(key: String, reviewed: SafariBookmarkService.WriteImpact) {
        if let write = pendingBrowserWrites[key], write.impact.destructiveSignature == reviewed.destructiveSignature {
            clearPendingBrowserWrite(key: key)
        }
        rejectedSafariWriteSignatures[key] = rejectionKey(reviewed.destructiveSignature)
        log("User kept [\(Self.reviewTarget(key))] bookmarks unchanged; discarded the change (\(reviewed.removed) removed, \(reviewed.moved) moved, \(reviewed.modified) modified).")
        presentNextPendingSafariWrite()
    }

    private func rejectPendingSafariWrite(from clientId: String, reviewed: SafariBookmarkService.WriteImpact) {
        if let write = pendingSafariWrites[clientId],
           write.held.impact.destructiveSignature == reviewed.destructiveSignature {
            clearPendingSafariWrite(for: clientId)
        }
        approvedSafariWriteSignatures.removeValue(forKey: clientId)
        log("User kept Safari bookmarks unchanged; discarded the change from [\(clientId)] (\(reviewed.removed) removed, \(reviewed.moved) moved, \(reviewed.modified) modified).")
        // Remember the reviewed change even if a newer one replaced it meanwhile:
        // the user has explicitly said no to this one.
        rejectedSafariWriteSignatures[clientId] = rejectionKey(reviewed.destructiveSignature)
        presentNextPendingSafariWrite()
    }

    /// Called when the user approves the change shown in the review window.
    private func applyPendingSafariWrite(from clientId: String, reviewedSignature: String, selectedNodeIds: Set<String>? = nil) {
        guard let write = validPendingSafariWrite(for: clientId) else {
            log("The reviewed Safari bookmark change from [\(clientId)] is no longer pending; nothing was written.")
            presentNextPendingSafariWrite()
            return
        }
        // A newer, different change replaced the reviewed one: show that instead.
        guard write.held.impact.signature == reviewedSignature else {
            presentPendingSafariWrite(from: clientId)
            return
        }
        clearPendingSafariWrite(for: clientId)
        func commit(_ held: SafariBookmarkService.HeldWrite) -> Int? {
            if let selectedNodeIds { return safariBookmarks.commitHeldWrite(held, selectedNodeIds: selectedNodeIds, from: write.sourceName) }
            return safariBookmarks.commitHeldWrite(held, from: write.sourceName)
        }
        log("User approved a large Safari bookmark change from [\(clientId)] (\(write.held.impact.removed) removed, \(write.held.impact.moved) moved, \(write.held.impact.modified) modified).")
        prepareSafariForIncomingBookmarkMutation()
        // Write exactly the reviewed result, and only onto the Safari file it
        // was computed from.
        if clientId.hasPrefix(Self.cleanupReviewKey) {
            if let count = commit(write.held) {
                lastNetworkSyncTime = Date()
                finishApprovedSafariWrite(count)
            } else if let fresh = clientId == Self.mobileCleanupKey
                        ? safariBookmarks.previewMobileContaminationCleanup()
                        : safariBookmarks.previewLeakedRootFolderCleanup() {
                if fresh.impact.signature == reviewedSignature, let count = safariBookmarks.commitHeldWrite(fresh, from: write.sourceName) {
                    finishApprovedSafariWrite(count)
                } else {
                    runSafariCleanup(fresh, key: clientId)
                }
            }
            presentNextPendingSafariWrite()
            return
        }
        if let restore = write.restore {
            // An explicit backup/history restore is the narrow exception to
            // one-way source read-only. Preserve that authorization through a
            // held Safe Mode review; bookmark Sync OFF is still enforced by
            // the service's final boundary.
            if let count = safariBookmarks.commitHeldWrite(write.held, from: write.sourceName, explicitRestore: true) {
                lastNetworkSyncTime = Date()
                finishApprovedSafariWrite(count)
            } else {
                // Safari changed during the review: recompute the restore; the
                // same change is written, a different one is reviewed again.
                let count = safariBookmarks.applyBookmarks(
                    restore.bookmarks,
                    from: write.sourceName,
                    isFullMirror: restore.replacing,
                    guardLargeChanges: true,
                    explicitRestore: true
                )
                if count == SafariBookmarkService.blockedLargeChange, let held = safariBookmarks.lastBlockedWrite {
                    guard held.impact.signature == reviewedSignature,
                          let committed = safariBookmarks.commitHeldWrite(held, from: write.sourceName, explicitRestore: true) else {
                        log("Safari bookmarks changed while the restore review was open; asking again.")
                        holdLargeSafariWrite(PendingSafariWrite(sourceName: write.sourceName, held: held, restore: restore), clientId: clientId)
                        return
                    }
                    finishApprovedSafariWrite(committed)
                } else if count >= 0 {
                    finishApprovedSafariWrite(count)
                }
            }
            presentNextPendingSafariWrite()
            return
        }
        if let count = commit(write.held) {
            lastNetworkSyncTime = Date()
            finishApprovedSafariWrite(count)
            if settings.bookmarkSyncStrategy != .twoWayMerge {
                // One-way: the held tree was not forwarded to the other
                // browsers; a fresh snapshot from the source now will be.
                requestFreshBookmarkSnapshot(for: clientId)
            }
        } else {
            // Safari changed meanwhile. The stored payload may be stale (the
            // other browser may since have converged), so never replay it: ask
            // for a fresh snapshot and write it only if it is the same change.
            approvedSafariWriteSignatures[clientId] = ApprovedSafariWrite(
                signature: reviewedSignature,
                settingsFingerprint: write.settingsFingerprint,
                expires: Date().addingTimeInterval(10 * 60)
            )
            log("Safari bookmarks changed while the review was open; requesting a fresh snapshot from [\(clientId)].")
            if clientId == "Safari" {
                scheduleBookmarkSyncSession()
            } else {
                requestFreshBookmarkSnapshot(for: clientId)
            }
        }
        presentNextPendingSafariWrite()
    }

    /// Menu bar "Resume": forget the refusal and look at the browser's current
    /// bookmarks again (a still-large change is reviewed again).
    func resumeBookmarkSync(from clientId: String) {
        guard rejectedSafariWriteSignatures.removeValue(forKey: clientId) != nil else { return }
        loggedRejectedSafariWriteSkips = loggedRejectedSafariWriteSkips.filter { !$0.hasPrefix(clientId) }
        log("User resumed bookmark sync for [\(clientId)].")
        if clientId.hasPrefix("to:") {
            let target = Self.reviewTarget(clientId)
            let record = clientId.hasPrefix("to:rm:") ? "rm:" + target : target
            if let message = lastBookmarkMessageByClient[record],
               let client = daemon?.connectedClients.first(where: { $0.id == target }) {
                daemon?.sendWSMessage(message, to: client)
            }
        } else if clientId == "Safari" {
            scheduleBookmarkSyncSession()
        } else {
            requestFreshBookmarkSnapshot(for: clientId)
        }
    }

    /// True while this browser's bookmarks are held for review or refused, so
    /// a stored snapshot of them must not be handed to other browsers.
    func hasHeldBookmarkChange(from browser: Browser) -> Bool {
        let prefix = browser.rawValue + "-"
        return pendingSafariWrites.keys.contains { $0.hasPrefix(prefix) }
            || rejectedSafariWriteSignatures.keys.contains { $0.hasPrefix(prefix) }
    }

    static let removalBatchCategory = "bookmarks_removed_batch"
    static let bookmarkPlanCapability = "bookmarkExecutorV2"
    private var notifiedOutdatedExtensions = Set<String>()
    private lazy var lastSettingsFingerprintSeen = bookmarkSettingsFingerprint

    /// Bookmark writes go only to thin executors that provide native snapshots,
    /// validate input tokens, replay app-planned operations and verify results.
    /// Safari is written natively; its extension never applies bookmarks.
    func mayWriteBookmarks(to client: ConnectedClient, explicitRestore: Bool = false) -> Bool {
        if client.browser == .safari { return false }
        guard BookmarkWritePolicy.allowsWrite(to: client.browser, settings: settings, explicitRestore: explicitRestore) else {
            log("Bookmark write to [\(client.id)] refused: sync is off, the browser is not participating, or it is the read-only one-way source.")
            return false
        }
        if client.capabilities.contains(Self.bookmarkPlanCapability) { return true }
        if notifiedOutdatedExtensions.insert(client.id).inserted {
            log("Bookmark sync to [\(client.id)] is paused: its extension is outdated and cannot review bookmark plans.")
            AppState.shared.notificationService.notifyOutdatedBookmarkExtension(browserName: Self.displayName(forClient: client.id))
        }
        return false
    }

    /// After the app itself wrote Safari, its snapshot must match; otherwise
    /// the next Safari sync takes what the app changed for user deletions.
    func refreshSafariSnapshot() {
        let fresh = safariBookmarks.readBookmarks()
        guard !fresh.isEmpty else { return }
        let all = fresh.map { b in
            Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
        }
        // Same folder-adjusted form Safari sync stores and diffs against.
        guard let snapshot = folderAdjustedBookmarksForSource(all, browser: .safari) else { return }
        backupService?.saveSnapshot(bookmarks: snapshot, sourceBrowser: "safari")
        bookmarkCounts["safari"] = snapshot.count
    }

    /// A backup restore into Safari. A caller that already presented an
    /// explicit restore confirmation may bypass duplicate Safe Mode review.
    @discardableResult
    func applyRestoreToSafari(_ bookmarks: [SyncBookmark], replacing: Bool, skipDuplicateReview: Bool = false) -> Bool {
        guard BookmarkWritePolicy.allowsWrite(to: .safari, settings: settings, explicitRestore: true) else {
            log("Safari restore refused by the final bookmark write policy.")
            return false
        }
        // Starting a restore is a new, explicit request: an earlier "Keep"
        // on a restore must not silently skip it.
        rejectedSafariWriteSignatures.removeValue(forKey: Self.restoreReviewKey)
        recordInternalWrite()
        let count = safariBookmarks.applyBookmarks(
            bookmarks,
            from: "Backup Restore",
            isFullMirror: replacing,
            guardLargeChanges: !skipDuplicateReview,
            bypassSafeModeReview: skipDuplicateReview,
            explicitRestore: true
        )
        if count == SafariBookmarkService.blockedLargeChange, let held = safariBookmarks.lastBlockedWrite {
            holdLargeSafariWrite(PendingSafariWrite(sourceName: "Backup Restore", held: held, restore: (bookmarks, replacing)), clientId: Self.restoreReviewKey)
            return false
        }
        guard count >= 0 else {
            log("Safari restore failed or was refused; it was not reported as successful.")
            return false
        }
        refreshSafariSnapshot()
        return true
    }

    /// Restores trash items only to the browsers in which the deletion was
    /// observed. The explicit user action bypasses duplicate Safe Mode review.
    /// Returns true only when every target was synchronously verified; an
    /// extension dispatch remains in the trash until its result is confirmed.
    @discardableResult
    func restoreDeletedBookmarks(_ bookmarks: [SyncBookmark], to targets: Set<Browser>) -> Bool {
        guard !bookmarks.isEmpty, !targets.isEmpty else { return false }
        var verified = true

        if targets.contains(.safari) {
            guard BookmarkWritePolicy.allowsWrite(to: .safari, settings: settings, explicitRestore: true),
                  SandboxAccessManager.shared.hasSafariAccess else { return false }
            var current = safariBookmarks.readBookmarks()
            current.append(contentsOf: bookmarks)
            recordInternalWrite()
            let safariVerified = applyRestoreToSafari(current, replacing: false, skipDuplicateReview: true)
            if safariVerified {
                backupService?.markDeletedBookmarksRestored(ids: Set(bookmarks.map(\.id)), from: .safari)
            }
            verified = safariVerified && verified
        }

        let payload = bookmarks.map { bookmark in
            Bookmark(
                id: bookmark.id,
                title: bookmark.title,
                url: bookmark.url,
                parentId: bookmark.parentId,
                isFolder: bookmark.isFolder,
                inBookmarksBar: bookmark.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }
        for browser in targets where browser != .safari {
            let message = WSMessage(
                type: .sync,
                site: "*",
                category: SyncCategory.bookmarks.rawValue,
                payload: .bookmarks(payload),
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970,
                isFullMirror: false,
                isExplicitDeletedBookmarkRestore: true
            )
            if let messageId = message.messageId {
                pendingDeletedRestoreByMessageId[messageId] = (Set(bookmarks.map(\.id)), browser)
            }
            sendBookmarkMessage(message, to: browser)
            // Extension writes are asynchronous and may wait for Safe Mode
            // review. Do not remove the trash entry before verified success.
            verified = false
        }
        return verified
    }

    /// Whether Safari's tree may be sent to this browser right now.
    func mayPushSafariBookmarks(to clientId: String) -> Bool {
        !isSafariPushDeferred(to: clientId)
    }

    private func requestFreshBookmarkSnapshot(for clientId: String) {
        // Safari's own deduplication is recomputed on its next push.
        guard let browser = Browser(rawValue: clientId.components(separatedBy: "-").first ?? clientId),
              browser != .safari else { return }
        let request = WSMessage(type: .sync, site: "*", category: "bookmarks", payload: nil, messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
        daemon?.broadcast(request, participatingBrowsers: [browser])
    }

    private func finishApprovedSafariWrite(_ count: Int) {
        log("Wrote \(count) bookmarks into Safari natively (App Store)")
        // Two-way: pushes deferred during the review (e.g. Safari edits made
        // meanwhile) are delivered now, from Safari's new state.
        refreshSafariSnapshot()
        // Safari's new state reaches the other browsers through a session.
        scheduleBookmarkSyncSession()
    }

    private func sendBookmarkMessage(_ message: WSMessage, to browser: Browser, excluding excludedId: String? = nil) {
        guard let daemon else { return }
        let explicitRestore = message.isExplicitDeletedBookmarkRestore == true || message.isExplicitBookmarkRestore == true
        for client in daemon.connectedClients where client.browser == browser && client.id != excludedId && mayWriteBookmarks(to: client, explicitRestore: explicitRestore) {
            // Pushing Safari's tree now would make that browser silently undo
            // the change the user is reviewing, and a later "Apply" would then
            // swap the two browsers' layouts. Deferred until the decision.
            if message.browser == Browser.safari.rawValue,
               message.category == SyncCategory.bookmarks.rawValue,
               isSafariPushDeferred(to: client.id) {
                log("Deferred pushing Safari bookmarks to [\(client.id)] until its pending review is decided.")
                continue
            }
            var targeted = message
            if case .bookmarks(let bookmarks) = targeted.payload,
               let sourceId = targeted.browser,
               let sourceBrowser = Browser(rawValue: sourceId) {
                targeted.payload = .bookmarks(
                    bookmarksPreparedForTarget(bookmarks, sourceBrowser: sourceBrowser, targetBrowser: browser)
                )
            }
            targeted.targetBookmarkFolder = settings.bookmarkFolder(for: browser)
            recordSentBookmarkMessage(targeted, to: client.id)
            daemon.sendWSMessage(targeted, to: client)
        }
    }

    private func broadcastBookmarkMessage(_ message: WSMessage, excluding excludedId: String? = nil) {
        for browser in settings.bookmarkParticipatingBrowsers {
            sendBookmarkMessage(message, to: browser, excluding: excludedId)
        }
    }

    private func snapshotForClient(_ clientId: String) -> [Bookmark] {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        return backupService?.getSnapshot(sourceBrowser: clientId)
            ?? backupService?.getSnapshot(sourceBrowser: browserId)
            ?? []
    }

    private func saveSnapshotAliases(bookmarks: [Bookmark], clientId: String) {
        backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: clientId)
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        if browserId != clientId {
            backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: browserId)
        }
    }

    /// Persisted history is the only previous/current state used for activity
    /// detection. Save first, then compare the newest two records.
    private func latestSnapshotDelta(for clientId: String) -> BookmarkSnapshotDelta? {
        guard let snapshots = backupService?.getRecentSnapshots(sourceBrowser: clientId, limit: 2),
              snapshots.count == 2 else { return nil }
        return BookmarkSnapshotDiffer.diff(older: snapshots[0], newer: snapshots[1])
    }


    /// A browser can briefly report an empty tree while its bookmark database is
    /// unavailable. Treating that as a full snapshot would erase every one-way
    /// target, so only accept it when this browser has never had bookmarks.
    private func shouldRejectUnexpectedEmptyBookmarkSnapshot(_ bookmarks: [Bookmark], from clientId: String) -> Bool {
        guard bookmarks.isEmpty else { return false }

        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        let previousCount = max(
            snapshotForClient(clientId).count,
            bookmarkCounts[browserId] ?? 0
        )
        guard previousCount > 0 else { return false }

        log("Rejected empty bookmark snapshot from [\(clientId)]: previous snapshot had \(previousCount) items. Existing bookmarks were left unchanged.")
        return true
    }

    func forceAcceptPendingEmptyBookmarkSnapshot(from clientId: String) {
        guard let pending = pendingEmptyBookmarkSnapshots.removeValue(forKey: clientId) else { return }
        prepareSafariForIncomingBookmarkMutation()
        var forcedMessage = pending.message
        let messageId = forcedMessage.messageId ?? UUID().uuidString
        forcedMessage.messageId = messageId
        forceAcceptedEmptyBookmarkMessageIds.insert(messageId)
        log("User forced synchronization of the empty bookmark snapshot from [\(clientId)].")
        receive(message: forcedMessage, from: pending.clientId)
    }

    /// Capture the target's current selected tree before an incoming browser can
    /// mutate it. This is intentionally invoked immediately before the native
    /// Safari write, never from the post-write monitor callback.
    private func backupCurrentSafariBookmarkFolderBeforeIncomingSync() {
        guard Date() >= suppressSafariPreSyncBackupUntil else {
            log("Skipped Safari automatic backup: this is a follow-up snapshot from an incoming bookmark mutation.")
            return
        }
        let folderPath = settings.bookmarkFolder(for: .safari)
        let bookmarks = safariBookmarks.readBookmarks().map {
            Bookmark(
                id: $0.id,
                title: $0.title,
                url: $0.url,
                parentId: $0.parentId,
                isFolder: $0.isFolder,
                sortIndex: $0.sortIndex,
                inBookmarksBar: $0.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }
        guard let selectedBookmarks = backupBookmarksForSource(bookmarks, browser: .safari) else {
            return
        }
        if backupService?.savePreSyncBackup(bookmarks: selectedBookmarks, sourceBrowser: "safari", folderPath: folderPath) == true {
            log("Saved Safari pre-write bookmark backup with \(selectedBookmarks.count) items.")
        } else {
            log("Skipped Safari pre-write bookmark backup because it is empty or unchanged from Safari's previous backup.")
        }
    }

    /// A deletion event is followed by one or more complete browser snapshots.
    /// Capture Safari before the first mutation and prevent those follow-ups from
    /// creating newer, post-mutation Safari backups.
    private func prepareSafariForIncomingBookmarkMutation() {
        backupCurrentSafariBookmarkFolderBeforeIncomingSync()
        suppressSafariPreSyncBackupUntil = Date().addingTimeInterval(15)
    }
    
    deinit {
        safariMonitorSource?.cancel()
        if safariMonitorFileDescriptor != -1 {
            close(safariMonitorFileDescriptor)
        }
    }

    // MARK: - Data Directories

    private func createDataDirectories() {
        let dirs = ["sites", "bookmarks", "history", "logs"]
        for dir in dirs {
            let url = dataDir.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Earlier versions queued undelivered deletions for offline browsers and
    /// replayed them as standalone removal batches. Missed changes now stay
    /// pending against the per-pair baselines, so the old queues are removed
    /// once instead of being re-sent (and refused) on every connection.
    private func removeLegacyRemovalQueues() {
        for name in ["pending-browser-bookmark-removals.json", "pending-safari-bookmark-removals.json"] {
            let url = dataDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func loadBookmarkCountsFromDisk() {
        let bookmarksDir = dataDir.appendingPathComponent("bookmarks")
        guard let files = try? FileManager.default.contentsOfDirectory(at: bookmarksDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let clientId = file.deletingPathExtension().lastPathComponent
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            guard let data = try? Data(contentsOf: file),
                  let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) else { continue }
            let existing = bookmarkCounts[browserId] ?? 0
            bookmarkCounts[browserId] = max(existing, bookmarks.count)
        }
        // Load Safari count from snapshot (Safari doesn't send JSON like Chromium)
        Task {
            let count = safariBookmarks.readBookmarks().count
            if count > 0 { bookmarkCounts["safari"] = count }
        }
    }
    
    // MARK: - Safari Bookmark Monitor
    
    /// Also called after the user grants Safari folder access at runtime
    /// (see BookmarkSyncTabView's "Grant Access" flow) since the monitor is
    /// a no-op at init() when no security-scoped bookmark has been saved yet.
    func startSafariBookmarkMonitor() {
        guard safariMonitorSource == nil else { return }
        SandboxAccessManager.shared.withSafariAccess {
            guard let url = SandboxAccessManager.shared.safariBookmarksPlistURL else { return }
        
        safariMonitorFileDescriptor = open(url.path, O_EVTONLY)
        guard safariMonitorFileDescriptor != -1 else { return }
        
        safariMonitorSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: safariMonitorFileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        
        safariMonitorSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            
            // 1. Re-arm monitor if file was deleted/replaced (e.g., atomic save)
            // This MUST be checked before returning, otherwise the monitor will detach forever
            let data = self.safariMonitorSource?.data
            if data?.contains(.delete) == true || data?.contains(.rename) == true {
                self.safariMonitorSource?.cancel()
                if self.safariMonitorFileDescriptor != -1 { close(self.safariMonitorFileDescriptor) }
                self.safariMonitorSource = nil
                self.safariMonitorFileDescriptor = -1
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startSafariBookmarkMonitor()
                }
            }
            
            // 2. Echo Cancellation: Ignore changes triggered by our own writes
            if now.timeIntervalSince(self.lastNetworkSyncTime) < 10.0 {
                self.log("Ignoring Safari Bookmarks.plist change (echo cancellation)")
                return
            }
            
            // 3. Debounce: Wait for 10 seconds of silence before triggering sync
            self.safariBookmarkDebounceTask?.cancel()
            self.safariBookmarkDebounceTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    if Task.isCancelled { return }
                    
                    let isPro = AppState.shared.purchaseService.isProUnlocked
                    let isAutoSyncEnabled = isPro && self.settings.bookmarkAutoSync && self.settings.enabledCategories.contains(.bookmarks)
                    if isAutoSyncEnabled {
                        self.log("Safari Bookmarks.plist changed! Triggering auto-sync...")
                        await self.syncCategory(.bookmarks)
                    }
                } catch {
                    // Task cancelled
                }
            }
        }
        
            safariMonitorSource?.resume()
            log("Started Safari Bookmarks.plist monitor for real-time sync")
        }
    }

    // MARK: - Sync Now

    func syncNow(categories: Set<SyncCategory>? = nil) async -> SyncStats {
        guard !isSyncing else { return SyncStats() }
        let syncID = UUID()
        activeManualSyncID = syncID
        lastManualSyncWasCancelled = false
        isSyncing = true
        currentManualSyncStats = SyncStats()
        
        let connectedClients = daemon?.connectedClients.map { "\($0.browser.rawValue)-\($0.id)" }.joined(separator: ", ") ?? "none"
        log("Starting manual sync... Connected clients: \(connectedClients)")
        AppState.shared.broadcastSettings()

        let targetCategories = categories ?? settings.enabledCategories
        if targetCategories.contains(.bookmarks), !rejectedSafariWriteSignatures.isEmpty {
            // An explicit Sync Now is the way back from "Keep Safari As Is":
            // refused changes are offered for review again.
            rejectedSafariWriteSignatures.removeAll()
            loggedRejectedSafariWriteSkips.removeAll()
            log("Cleared earlier decisions to keep Safari unchanged; large changes will be reviewed again.")
        }
        // Clean up any mobile bookmark contamination in Safari before syncing
        if targetCategories.contains(.bookmarks), safariMutationIsAuthorized {
            prepareSafariForIncomingBookmarkMutation()
            runSafariCleanup(safariBookmarks.previewMobileContaminationCleanup(), key: Self.mobileCleanupKey)
        }
        // Read pre-sync Safari bookmarks on all builds (sandbox access handled inside readBookmarks)
        let preSyncSafariBookmarks = targetCategories.contains(.bookmarks) ? safariBookmarks.readBookmarks() : []
        if !preSyncSafariBookmarks.isEmpty { bookmarkCounts["safari"] = preSyncSafariBookmarks.count }
        for category in SyncCategory.allCases where targetCategories.contains(category) {
            await syncCategory(category)
            guard manualSyncIsActive(syncID) else { return SyncStats() }
        }
        
        // Wait for clients to respond before ending manual sync window
        // But don't wait at all if no clients connected
        let hasClients = (daemon?.connectedClients.isEmpty == false)
        if hasClients {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }

        guard manualSyncIsActive(syncID) else { return SyncStats() }

        if targetCategories.contains(.bookmarks) {
            // Every browser's snapshot has been persisted. One session now
            // detects all local changes against the per-target baselines,
            // plans every target together and opens one review.
            startBookmarkSyncSession(manual: true)
        }

        lastSyncDate = Date()
        isSyncing = false
        activeManualSyncID = nil
        if targetCategories.contains(.bookmarks) {
            let postSyncSafariBookmarks = safariBookmarks.readBookmarks()
            currentManualSyncStats.bookmarks = postSyncSafariBookmarks.filter { !$0.isFolder }.count
            currentManualSyncStats.bookmarkFolders = postSyncSafariBookmarks.filter(\.isFolder).count
            if !postSyncSafariBookmarks.isEmpty { bookmarkCounts["safari"] = postSyncSafariBookmarks.count }
            
            let prevMap = Dictionary(uniqueKeysWithValues: preSyncSafariBookmarks.map { ($0.id, $0) })
            let newMap = Dictionary(uniqueKeysWithValues: postSyncSafariBookmarks.map { ($0.id, $0) })
            
            for (id, bm) in newMap {
                if let p = prevMap[id] {
                    if p.title != bm.title || p.url != bm.url || p.parentId != bm.parentId {
                        if bm.isFolder {
                            currentManualSyncStats.bookmarkFoldersModified += 1
                        } else {
                            currentManualSyncStats.bookmarksModified += 1
                        }
                    }
                } else {
                    if bm.isFolder {
                        currentManualSyncStats.bookmarkFoldersAdded += 1
                    } else {
                        currentManualSyncStats.bookmarksAdded += 1
                    }
                }
            }
            for id in prevMap.keys {
                if newMap[id] == nil, let previous = prevMap[id] {
                    if previous.isFolder {
                        currentManualSyncStats.bookmarkFoldersDeleted += 1
                    } else {
                        currentManualSyncStats.bookmarksDeleted += 1
                    }
                }
            }
        }
        log("Sync complete (Bookmarks: \(currentManualSyncStats.bookmarks), Cookies: \(currentManualSyncStats.cookies), LocalStorage: \(currentManualSyncStats.localStorage), SessionStorage: \(currentManualSyncStats.sessionStorage))")
        NotificationCenter.default.post(name: .browSyncDidComplete, object: self)
        return currentManualSyncStats
    }

    func prepareSilentBrowserDataPull(to requesterClientId: String, site: String?) {
        pruneExpiredSilentBrowserDataPulls()
        silentBrowserDataPulls.removeAll { $0.requesterClientId == requesterClientId }
        silentBrowserDataPulls.append(
            SilentBrowserDataPull(
                requesterClientId: requesterClientId,
                site: normalizedSite(site),
                // A browser can still be draining an older cookie batch when
                // the requested site snapshot arrives. Keep this repair window
                // long enough for that queue without retaining it indefinitely.
                expiresAt: Date().addingTimeInterval(30)
            )
        )
    }

    private func pruneExpiredSilentBrowserDataPulls() {
        let now = Date()
        silentBrowserDataPulls.removeAll { $0.expiresAt < now }
    }

    private func silentBrowserDataPullRequesters(for message: WSMessage, from clientId: String) -> [String] {
        guard let category = message.category,
              category == "cookies" || category == "localStorage" || category == "sessionStorage" else {
            return []
        }

        pruneExpiredSilentBrowserDataPulls()
        return silentBrowserDataPulls.compactMap { pull in
            guard pull.requesterClientId != clientId else { return nil }
            guard silentPull(pull, matches: message) else { return nil }
            return pull.requesterClientId
        }
    }

    private func silentPull(_ pull: SilentBrowserDataPull, matches message: WSMessage) -> Bool {
        guard let site = pull.site, site != "*" else { return true }
        if let messageSite = normalizedSite(message.site), messageSite == "*" || host(messageSite, matches: site) {
            return true
        }

        switch message.payload {
        case .cookies(let cookies):
            return cookies.contains { host($0.domain, matches: site) }
        case .localStorage(let items), .sessionStorage(let items):
            return items.contains { item in
                guard let originHost = URL(string: item.origin)?.host else { return host(item.origin, matches: site) }
                return host(originHost, matches: site)
            }
        default:
            return true
        }
    }

    private func normalizedSite(_ site: String?) -> String? {
        guard var site = site?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty else { return nil }
        if let host = URL(string: site)?.host {
            site = host
        }
        if site.hasPrefix(".") { site.removeFirst() }
        return site
    }

    private func syncedSites(for payload: WSPayload, site: String?) -> Set<String> {
        func displaySite(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "*" else { return nil }
            let host = URL(string: trimmed)?.host ?? trimmed
            let normalized = host.hasPrefix(".") ? String(host.dropFirst()) : host
            return normalized.isEmpty ? nil : normalized
        }

        switch payload {
        case .cookies(let cookies):
            return Set(cookies.compactMap { displaySite($0.domain) })
        case .localStorage(let items), .sessionStorage(let items):
            return Set(items.compactMap { displaySite($0.origin) })
        default:
            return Set(site.flatMap(displaySite).map { [$0] } ?? [])
        }
    }

    private func host(_ host: String, matches site: String) -> Bool {
        let cleanHost = normalizedSite(host) ?? host.lowercased()
        let cleanSite = normalizedSite(site) ?? site.lowercased()
        return cleanHost == cleanSite || cleanHost.hasSuffix("." + cleanSite) || cleanSite.hasSuffix("." + cleanHost)
    }

    private func syncCategory(_ category: SyncCategory) async {
        log("Syncing: \(category.displayName)")

        let strategy = settings.bookmarkSyncStrategy
        let sourceBrowser = settings.bookmarkSourceBrowser

        if category == .bookmarks {
            // Determine if we should push Safari to others
            let shouldPushSafari = (strategy == .twoWayMerge || (strategy == .oneWay && sourceBrowser == .safari)) && settings.bookmarkParticipatingBrowsers.contains(.safari)
            
            if shouldPushSafari {
                let safariBms = safariBookmarks.readBookmarks()
                if !safariBms.isEmpty {
                    let rawBookmarks = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                    if let bookmarks = folderAdjustedBookmarksForSource(rawBookmarks, browser: .safari),
                       let backupBookmarks = backupBookmarksForSource(rawBookmarks, browser: .safari) {
                        backupService?.savePreSyncBackup(
                            bookmarks: backupBookmarks,
                            sourceBrowser: "safari",
                            folderPath: settings.bookmarkFolder(for: .safari)
                        )
                        // Safari's observation is persisted like any other
                        // browser's. Changes are derived later, together
                        // with every other browser, by the sync session.
                        backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: "safari")
                        bookmarkCounts["safari"] = bookmarks.count
                        if !isSyncing { scheduleBookmarkSyncSession() }
                        log("Recorded Safari bookmark snapshot (\(bookmarks.count) items).")
                    } else {
                        log("Skipped Safari bookmark observation because its selected sync folder is missing; continuing with other browsers.")
                    }
                } else {
                    log("No Safari bookmarks found to sync")
                }
            }

            // Determine if we should pull from others. In one-way mode we must
            // only pull from the configured source browser; otherwise an empty
            // target browser can become the full-mirror source and wipe data.
            if strategy == .oneWay && sourceBrowser != .safari {
                guard settings.bookmarkParticipatingBrowsers.contains(sourceBrowser) else {
                    log("Skipped one-way bookmark pull because \(sourceBrowser.displayName) is not participating in sync.")
                    return
                }
                let requestMessage = WSMessage(
                    type: .sync,
                    site: "*",
                    category: category.rawValue,
                    payload: nil,
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                daemon?.broadcast(requestMessage, participatingBrowsers: [sourceBrowser])
            } else if strategy == .twoWayMerge {
                let requestMessage = WSMessage(
                    type: .sync,
                    site: "*",
                    category: category.rawValue,
                    payload: nil,
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                daemon?.broadcast(requestMessage, participatingBrowsers: settings.bookmarkParticipatingBrowsers)
            }
        } else {
            // For other categories, we just pull from everyone for now
            let requestMessage = WSMessage(
                type: .sync,
                site: "*",
                category: category.rawValue,
                payload: nil,
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970
            )
            daemon?.broadcast(requestMessage)
            
            // Proactively push the globally cached state from the central app.
            // This ensures that if the primary state source browser is not running,
            // we still sync the latest accumulated state to all connected browsers.
            let cachedPayloads = GlobalStateStore.shared.pull(category: category.rawValue)
            for payloadData in cachedPayloads {
                if let msg = try? JSONDecoder().decode(WSMessage.self, from: payloadData) {
                    if msg.category == "cookies", case .cookies(let cookies) = msg.payload {
                        let liveOnly = cookies.filter { $0.removed != true }
                        if liveOnly.isEmpty { continue }
                        var cleaned = msg
                        cleaned.payload = .cookies(liveOnly)
                        daemon?.broadcast(cleaned)
                    } else {
                        daemon?.broadcast(msg)
                    }
                }
            }
        }
    }

    // MARK: - Receive Sync Data

    func receive(message: WSMessage, from clientId: String) {
        guard message.type == .sync, let category = message.category else { return }

        if (category == "bookmarks" || category == "bookmark_changed" || category == "bookmarks_removed"),
           let until = ignoreBookmarkObservationsUntil {
            if until > Date() {
                log("Ignored late bookmark observation from [\(clientId)] after this manual sync was cancelled.")
                return
            }
            ignoreBookmarkObservationsUntil = nil
        }
        
        var filteredMessage = message
        if category == "bookmark_plan_context" {
            handleBookmarkPlanContext(message, clientId: clientId)
            return
        }
        // A per-site browserData pull is a repair operation: the requester may
        // have lost a cookie while the source still has the same version. Keep
        // the requester before conflict filtering so an unchanged snapshot can
        // be sent back instead of being mistaken for a duplicate update.
        let silentPullRequesters = silentBrowserDataPullRequesters(for: message, from: clientId)

        // This is the hard master gate for all state payloads.  It must run
        // before filtering, persistence, statistics, or notifications: an
        // extension worker can still emit an already-queued cookie event after
        // the app has broadcast that State Sync was turned off.
        let isStatePayload = category == "browserData" || category == "cookies" || category == "localStorage" || category == "sessionStorage"
        guard !isStatePayload || settings.enabledCategories.contains(.browserData) else {
            log("Ignored \(category) data from [\(clientId)] because State Sync is disabled.")
            return
        }

        if category == "bookmark_folder_missing" {
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId),
               case .raw(let raw) = message.payload,
               let folder = raw["folder"]?.value as? String {
                markMissingBookmarkFolder(browser, folder: folder)
            }
            return
        }

        if category == "bookmark_changed" {
            handleIncomingBookmarkChangeSignal(clientId: clientId)
            return
        }

        if category == "bookmark_incremental" {
            // Legacy merge payloads bypass the scoped native planner; they are
            // never written anywhere. Request a full observation instead.
            log("Ignored a legacy incremental bookmark payload from [\(clientId)]; requesting a full snapshot.")
            requestFreshBookmarkSnapshot(for: clientId)
            return
        }

        if category == "bookmark_roots" {
            logBookmarkRoots(message, clientId: clientId)
            return
        }

        if category == "bookmark_apply_held" {
            handleHeldBrowserWrite(message, clientId: clientId)
            return
        }

        if category == "bookmark_apply_result" {
            handleBrowserWriteResult(message, clientId: clientId)
            return
        }
        
        // Capture previous snapshot for auto-sync notifications before it gets overwritten.
        let preSyncAutoBookmarks = snapshotForClient(clientId)
        
        if category == "bookmarks" || category == "bookmark_incremental" || category == "bookmarks_removed" || category == "bookmark_backup" || category == "tabSharing" {
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId) {
                // Ensure the message carries the verified true sender ID
                filteredMessage.browser = browserId
                
                let participating = category == "tabSharing" ? settings.tabSharingParticipatingBrowsers : settings.bookmarkParticipatingBrowsers
                if !participating.contains(browser) {
                    log("Ignored \(category) data from [\(clientId)] because it is not participating in sync.")
                    return
                }
            }
        }
        
        // Respect One-Way Sync Strategy for ALL incoming bookmark data
        let strategy = settings.bookmarkSyncStrategy
        let sourceBrowser = settings.bookmarkSourceBrowser
        let isBookmarkCategory = (category == "bookmarks" || category == "bookmark_incremental" || category == "bookmarks_removed")
        let isOneWayTargetObservation = strategy == .oneWay && !isClient(clientId, from: sourceBrowser)

        if isBookmarkCategory && isOneWayTargetObservation && category != "bookmarks" {
            log("Ignored \(category) from [\(clientId)] due to one-way sync strategy (\(sourceBrowser.displayName) is primary)")
            
            // Even though we ignore it for syncing, we MUST update this client's local snapshot/count
            // so the UI reflects its actual state (e.g. user deleted a bookmark in Chrome).
            if category == "bookmarks_removed" || category == "bookmark_incremental" {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let req = WSMessage(
                        type: .sync,
                        site: "*",
                        category: "bookmarks",
                        payload: nil,
                        messageId: UUID().uuidString,
                        timestamp: Date().timeIntervalSince1970
                    )
                    await MainActor.run {
                        if let b = Browser(rawValue: clientId.components(separatedBy: "-").first ?? clientId) {
                            self.daemon?.broadcast(req, participatingBrowsers: [b])
                        }
                    }
                }
            }
            return
        }
        if category == "bookmark_backup", case .bookmarks(let bms) = filteredMessage.payload {
            // Browser extensions send this immediately before mutating their
            // local tree. Keep it both as the deletion-detection snapshot and
            // as a user-visible, restorable automatic backup.
            guard !shouldRejectUnexpectedEmptyBookmarkSnapshot(bms, from: clientId) else { return }
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId),
               let backupBookmarks = backupBookmarksForSource(bms, browser: browser) {
                let didSaveBackup = backupService?.savePreSyncBackup(
                    bookmarks: backupBookmarks,
                    sourceBrowser: clientId,
                    folderPath: settings.bookmarkFolder(for: browser)
                ) ?? false
                log(didSaveBackup
                    ? "Saved pre-write bookmark backup from [\(clientId)] with \(backupBookmarks.count) items; backup is not broadcast as sync data."
                    : "Skipped pre-write bookmark backup from [\(clientId)] because it is empty or unchanged from that browser's previous backup.")
            }
            bookmarkCounts[browserId] = bms.count
            return
        }
        if category == "bookmarks", case .bookmarks(let bms) = filteredMessage.payload {
            let wasForceAccepted = filteredMessage.messageId.map {
                forceAcceptedEmptyBookmarkMessageIds.remove($0) != nil
            } ?? false
            if !wasForceAccepted, shouldRejectUnexpectedEmptyBookmarkSnapshot(bms, from: clientId) {
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                let previousCount = max(preSyncAutoBookmarks.count, bookmarkCounts[browserId] ?? 0)
                pendingEmptyBookmarkSnapshots[clientId] = PendingEmptyBookmarkSnapshot(message: filteredMessage, clientId: clientId)
                AppState.shared.notificationService.notifyUnexpectedEmptyBookmarkSnapshot(
                    source: clientId,
                    previousCount: previousCount
                )
                if let browser = Browser(rawValue: browserId) { resolveManualBackup(browser, saved: false) }
                return
            }
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            let browser = Browser(rawValue: browserId)
            guard let sourceBrowserForFolder = browser else {
                return
            }

            // Normalize the complete observation to the configured source
            // scope before persisting it. The observation itself is never a
            // plan; the newest two persisted observations are diffed below.
            guard let sourceAdjustedBookmarks = folderAdjustedBookmarksForSource(bms, browser: sourceBrowserForFolder) else {
                resolveManualBackup(sourceBrowserForFolder, saved: false)
                return
            }
            // Record the source-side state produced by this local operation
            // before it is dispatched to any target. Target-side pre-write
            // backups are captured independently immediately before replay.
            if manualBackupRun?.waiting.contains(sourceBrowserForFolder) == true {
                // Answer to "Back Up Now": an unconditional, kept backup.
                let saved = backupBookmarksForSource(bms, browser: sourceBrowserForFolder).map {
                    backupService?.saveManualBackup(bookmarks: $0, sourceBrowser: clientId,
                                                    folderPath: settings.bookmarkFolder(for: sourceBrowserForFolder)) ?? false
                } ?? false
                resolveManualBackup(sourceBrowserForFolder, saved: saved)
            } else if let sourceBackup = backupBookmarksForSource(bms, browser: sourceBrowserForFolder) {
                let saved = backupService?.savePreSyncBackup(
                    bookmarks: sourceBackup,
                    sourceBrowser: clientId,
                    folderPath: settings.bookmarkFolder(for: sourceBrowserForFolder)
                ) ?? false
                if saved {
                    log("Saved source operation snapshot from [\(clientId)] before bookmark dispatch.")
                }
            }
            saveSnapshotAliases(bookmarks: sourceAdjustedBookmarks, clientId: clientId)
            save(sourceAdjustedBookmarks, to: dataDir.appendingPathComponent("bookmarks").appendingPathComponent("\(clientId).json"))
            bookmarkCounts[browserId] = sourceAdjustedBookmarks.count

            // The post-write tree a sync session asked for only moves that
            // session's baselines; it is not a new local change.
            if let browser, acceptSessionFreshSnapshot(from: browser) {
                log("Recorded the post-write bookmark tree from [\(clientId)].")
                return
            }

            if isOneWayTargetObservation {
                let snapshotDelta = latestSnapshotDelta(for: clientId)
                // The target's delta is evidence of drift, never a source of
                // writes. Reconcile this one target against the latest saved
                // source snapshot; the native planner will compare that state
                // with the target's current tree and review the actual diff.
                guard let snapshotDelta, !snapshotDelta.isEmpty,
                      let target = browser,
                      !snapshotForClient(sourceBrowser.rawValue).isEmpty else {
                    log("Recorded one-way target snapshot from [\(clientId)]; no source-driven correction was needed.")
                    return
                }
                var correction = WSMessage(
                    type: .sync,
                    browser: sourceBrowser.rawValue,
                    site: "*",
                    category: SyncCategory.bookmarks.rawValue,
                    payload: .bookmarks(snapshotForClient(sourceBrowser.rawValue)),
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                correction.isFullMirror = true
                sendBookmarkMessage(correction, to: target)
                log("Calculated one-way correction for [\(clientId)] from the latest \(sourceBrowser.displayName) snapshot.")
                return
            }

            // Snapshots are observations. Changes are detected by comparing
            // each browser's newest snapshot with its persisted per-target
            // sync baseline, for all browsers together, in one session.
            if !isSyncing { scheduleBookmarkSyncSession() }
            log("Recorded bookmark snapshot from [\(clientId)] (\(sourceAdjustedBookmarks.count) items).")
            return
        }

        if category == "bookmarks_removed" {
            // Extension callbacks wake the app only. The persisted snapshot
            // delta above is the deletion authority.
            handleIncomingBookmarkChangeSignal(clientId: clientId)
            return
        }

        if category == "cookie_apply_result" {
            if case .raw(let raw) = filteredMessage.payload,
               let summary = raw["summary"]?.value as? String {
                if !summary.hasSuffix("0 failed") {
                    // Extensions append "; details: domain/path::name ..." for
                    // failures. Only the counts may reach the persistent log.
                    let counts = String((summary.components(separatedBy: ";").first ?? "")
                        .filter { $0.isLetter || $0.isNumber || " ,".contains($0) }
                        .prefix(64))
                    log("Cookie apply result from [\(clientId)]: \(counts)")
                }
            }
            return
        }
        
        // Filter incoming browser data based on website list policy
        if category == "browserData" || category == "localStorage" || category == "sessionStorage" || category == "cookies", let payload = message.payload {
            let policy = settings.websiteListPolicy
            
            switch payload {
            case .cookies(let cookies):
                let filtered = filterCookies(
                    cookies,
                    clientId: clientId,
                    policy: policy,
                    acceptingUnchangedSnapshot: !silentPullRequesters.isEmpty
                )
                if filtered.isEmpty {
                    return
                }
                filteredMessage.payload = .cookies(filtered)
                logCookieDomains(filtered, clientId: clientId)
            case .localStorage(let items):
                let filtered = filterStorageItems(items, clientId: clientId, policy: policy)
                if filtered.isEmpty {
                    return
                }
                filteredMessage.payload = .localStorage(filtered)
            case .sessionStorage(let items):
                let filtered = filterStorageItems(items, clientId: clientId, policy: policy)
                if filtered.isEmpty {
                    return
                }
                filteredMessage.payload = .sessionStorage(filtered)
            default: break
            }
        }

        if category == "tabSharing", case .tabs(let tabs) = filteredMessage.payload {
            let limitedTabs = ProLimits.limitedTabsForSharing(tabs, isProUnlocked: AppState.shared.purchaseService.isProUnlocked)
            filteredMessage.payload = .tabs(limitedTabs)
        }
        
        var countStr = ""
        if let payload = filteredMessage.payload {
            let involvedSites = syncedSites(for: payload, site: filteredMessage.site)
            if isSyncing {
                currentManualSyncStats.syncedSites.formUnion(involvedSites)
            }
            switch payload {
            case .bookmarks(let b): 
                countStr = " (\(b.count) items)"
            case .tabs(let t): 
                countStr = " (\(t.count) items)"
                if isSyncing { currentManualSyncStats.tabs += t.count }
            case .cookies(let c): 
                countStr = " (\(c.count) items)"
                if isSyncing { currentManualSyncStats.cookies += c.count }
            case .localStorage(let l): 
                countStr = " (\(l.count) items)"
                if isSyncing { currentManualSyncStats.localStorage += l.count }
            case .sessionStorage(let s): 
                countStr = " (\(s.count) items)"
                if isSyncing { currentManualSyncStats.sessionStorage += s.count }
            default: break
            }
        }
        
        log("Received sync data from [\(clientId)]: \(category)\(countStr)")

        // Do not rebroadcast a requested snapshot as a new automatic update.
        // Its sole purpose is to restore the requesting browser, including
        // session cookies whose updatedAt timestamp has not changed.
        if !silentPullRequesters.isEmpty {
            for requesterId in silentPullRequesters {
                daemon?.send(filteredMessage, toClientId: requesterId)
            }
            log("Delivered requested \(category) snapshot from [\(clientId)] to \(silentPullRequesters.count) browser(s).")
            return
        }

        // Apply conflict resolution and persist
        if let payload = filteredMessage.payload {
            currentMessageSafariWriteWasHeld = false
            persist(payload: payload, category: category, from: clientId, isFullMirror: filteredMessage.isFullMirror ?? false)
            
            if category == "tabSharing", case .tabs(let tabs) = payload {
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                if let browser = Browser(rawValue: browserId) {
                    let localDeviceName = Host.current().localizedName ?? "Local Device"
                    let localTabs = tabs.map { tab -> BrowserTab in
                        var modifiedTab = tab
                        modifiedTab.deviceName = localDeviceName
                        return modifiedTab
                    }
                    
                    let existingRemote = AppState.shared.remoteTabsCache[browser]?.filter { $0.id.hasPrefix("icloud_") } ?? []
                    AppState.shared.remoteTabsCache[browser] = localTabs + existingRemote
                }
            }
            
            // Auto-sync Notification
            if !isSyncing && AppState.shared.settingsService.general.notifySyncComplete {
                var autoStats = SyncStats()
                autoStats.syncedSites = syncedSites(for: payload, site: filteredMessage.site)
                switch payload {
                case .bookmarks(let bookmarks):
                    // A held or refused change was not applied; reporting its
                    // moves as "synced" would contradict the review prompt.
                    if currentMessageSafariWriteWasHeld { break }
                    if let source = Browser(rawValue: clientId.components(separatedBy: "-").first ?? clientId) {
                        autoStats.bookmarkSourceBrowserIds.insert(source.id)
                    }
                    // Notifications summarize the accepted snapshot delta,
                    // not an inferred difference between unrelated browsers.
                    populateAutomaticBookmarkChangeStats(
                        previous: preSyncAutoBookmarks,
                        current: bookmarks,
                        stats: &autoStats,
                        ignoringSafariEchoFor: clientId
                    )
                    
                case .cookies(let c): autoStats.cookies = c.count
                case .localStorage(let l): autoStats.localStorage = l.count
                case .sessionStorage(let s): autoStats.sessionStorage = s.count
                default: break
                }
                
                if !autoStats.isEmpty {
                    var categories: [SyncCategory] = []
                    if autoStats.bookmarksAdded > 0 || autoStats.bookmarksDeleted > 0 || autoStats.bookmarksModified > 0 ||
                        autoStats.bookmarkFoldersAdded > 0 || autoStats.bookmarkFoldersDeleted > 0 || autoStats.bookmarkFoldersModified > 0 {
                        categories.append(.bookmarks)
                    }
                    if autoStats.stateItems > 0 { categories.append(.browserData) }
                    
                    if !categories.isEmpty {
                        AppState.shared.notificationService.notifyAutoSyncComplete(stats: autoStats, categories: categories)
                    }
                }
            }
            
            let isBookmarkCategory = (category == "bookmarks" || category == "bookmarks_removed" || category == "bookmark_backup")
            let isPro = AppState.shared.purchaseService.isProUnlocked
            let effectiveBookmarkAutoSync = isPro && settings.bookmarkAutoSync && settings.enabledCategories.contains(.bookmarks)
            // The State Sync master switch is authoritative for both manual and
            // automatic traffic.  Previously it only disabled the SwiftUI form;
            // cookie/storage events could still be received and broadcast while
            // real-time auto sync remained enabled.
            let effectiveAutomaticSync = isPro && settings.automaticSync && settings.enabledCategories.contains(.browserData)
            let shouldSync = isBookmarkCategory ? (effectiveBookmarkAutoSync || isSyncing) : (effectiveAutomaticSync || isSyncing)
            
            if shouldSync {
                // Don't cache bookmarks in GlobalStateStore — they must always reflect
                // the current state of the source browser, not a stale snapshot.
                if category != "bookmarks" && category != "bookmark_backup" {
                    if filteredMessage.site == nil {
                        switch filteredMessage.payload {
                        case .cookies(let cookies):
                            let byDomain = Dictionary(grouping: cookies, by: { $0.domain })
                            for (domain, domainCookies) in byDomain {
                                var msg = filteredMessage
                                msg.site = domain
                                msg.payload = .cookies(domainCookies)
                                GlobalStateStore.shared.save(message: msg)
                            }
                        case .localStorage(let items):
                            let byOrigin = Dictionary(grouping: items, by: { $0.origin })
                            for (origin, originItems) in byOrigin {
                                var msg = filteredMessage
                                msg.site = origin
                                msg.payload = .localStorage(originItems)
                                GlobalStateStore.shared.save(message: msg)
                            }
                        case .sessionStorage(let items):
                            let byOrigin = Dictionary(grouping: items, by: { $0.origin })
                            for (origin, originItems) in byOrigin {
                                var msg = filteredMessage
                                msg.site = origin
                                msg.payload = .sessionStorage(originItems)
                                GlobalStateStore.shared.save(message: msg)
                            }
                        default: break
                        }
                    } else {
                        GlobalStateStore.shared.save(message: filteredMessage)
                    }
                }
                
                // Broadcast cookies to all clients.
                // If any live cookie just beat a tombstone winner, the sender's cookie
                // may have already been deleted by the tombstone broadcast — send it back
                // to everyone (including the sender) so it gets restored.
                if category == "cookies", case .cookies(let cookies) = filteredMessage.payload {
                    let hasResurrection = cookies.contains { c in
                        let removed = c.removed == true
                        return !removed && tombstoneWinnerKeys.contains(cookieVersionKey(c))
                    }
                    if hasResurrection {
                        log("Broadcasting cookies to ALL (including sender) — live cookie resurrects a previously deleted one")
                        daemon?.broadcast(filteredMessage, excluding: nil)
                    } else {
                        daemon?.broadcast(filteredMessage, excluding: clientId)
                    }
                } else if isBookmarkCategory {
                    // A Safari-native write may be held for review, but that
                    // must not turn Safari into the sole target.  The same
                    // source delta still needs an app-generated plan for every
                    // other participating browser (for example Edge -> both
                    // Safari and Chrome).  Each target remains independently
                    // staged and cannot execute until the aggregate review is
                    // applied.
                    broadcastBookmarkMessage(filteredMessage, excluding: clientId)
                } else {
                    daemon?.broadcast(filteredMessage, excluding: clientId)
                }
            } else if category == "tabSharing" {
                // For tab sharing, we always broadcast to others immediately, without checking auto-sync rules
                daemon?.broadcast(filteredMessage, excluding: clientId)
            } else {
                for requesterId in silentBrowserDataPullRequesters(for: filteredMessage, from: clientId) {
                    daemon?.send(filteredMessage, toClientId: requesterId)
                }
                log("Automatic sync is disabled. Received data but did not broadcast.")
            }
        }
    }

    private func presentBookmarkConflicts(_ pending: PendingBookmarkConflictResolution) {
        // Conflicts belong to the aggregate bookmark-review window.  They are
        // not serial system alerts: all affected browsers and all choices are
        // visible together with the rest of this sync plan.
        guard pendingBookmarkConflictResolution == nil else { return }
        var pending = pending
        let source = pending.input.message.browser.flatMap(Browser.init(rawValue:))
        let currentTarget = pending.input.browser
        pending.propagationTargets = settings.bookmarkParticipatingBrowsers
            .filter { browser in
                browser != currentTarget
                    && browser != .safari
                    && source.map { $0 != browser } != false
            }
            .sorted { $0.rawValue < $1.rawValue }
        pendingBookmarkConflictResolution = pending
        presentPendingBookmarkConflictReview()
    }

    private func presentPendingBookmarkConflictReview() {
        guard BookmarkChangeReviewWindowController.shared.presentedClientId == nil,
              pendingBookmarkConflictResolution != nil else { return }
        BookmarkChangeReviewWindowController.shared.present(
            clientId: pendingBookmarkConflictRouteID,
            reviewRoutes: pendingReviewRoutes,
            onApplySelected: { [weak self] selection, conflicts, _ in
                self?.applySelectedPendingBookmarkReviews(selection, conflictResolutions: conflicts)
            },
            onCancel: { [weak self] in self?.cancelPendingBookmarkReview() }
        )
    }

    /// The choices in the aggregate review are the explicit confirmation for
    /// these exact operations.  Dispatch only the freshly replanned result;
    /// the extension still validates the current token and verifies the write.
    private func applyPendingBookmarkConflictResolutions(
        _ resolutions: [String: BookmarkConflictResolution],
        propagationTargets: Set<Browser>
    ) {
        guard let pending = pendingBookmarkConflictResolution else { return }
        guard pending.conflicts.allSatisfy({ resolutions[$0.id] != nil }) else { return }
        pendingBookmarkConflictResolution = nil
        let plan = NativeBookmarkPlanner.makePlan(
            desired: pending.desired,
            context: pending.context,
            fullMirror: pending.input.message.isFullMirror == true,
            conflictResolutions: resolutions
        )
        guard plan.validationError == nil, plan.conflicts.isEmpty else {
            log("Bookmark conflict choices were discarded because the source or target changed.")
            return
        }
        if !plan.operations.isEmpty {
            var message = pending.input.message
            message.category = "bookmark_apply_plan"
            message.payload = .raw([
                "inputToken": AnyCodable(plan.inputToken),
                "operations": AnyCodable(plan.operations.map { op in
                    ["type": op.kind.rawValue, "id": op.id, "sourceId": op.sourceId as Any, "parentId": op.parentId as Any,
                     "index": op.index as Any, "title": op.title as Any, "url": op.url as Any]
                })
            ])
            guard let client = daemon?.connectedClients.first(where: { $0.id == pending.input.clientId }) else {
                log("Bookmark conflict was resolved, but the target browser disconnected before dispatch. Nothing was written.")
                return
            }
            if let messageId = message.messageId { dispatchedNativePlans[messageId] = plan.operations }
            daemon?.sendWSMessage(message, to: client)
            log("Dispatched \(plan.operations.count) user-confirmed bookmark conflict resolution operation(s) to [\(pending.input.clientId)].")
        } else {
            log("Bookmark conflict required no write into [\(pending.input.clientId)].")
        }
        stageResolvedConflictForRemainingTargets(
            pending,
            resolutions: resolutions,
            propagationTargets: propagationTargets
        )
    }

    /// A two-sided conflict is not the whole sync scope. Once the user has
    /// selected its result, every other participating writable browser must
    /// receive a plan as well. In particular, a browser that lacks the item
    /// (for example Edge) receives an add plan instead of being omitted.
    private func stageResolvedConflictForRemainingTargets(
        _ pending: PendingBookmarkConflictResolution,
        resolutions: [String: BookmarkConflictResolution],
        propagationTargets: Set<Browser>
    ) {
        var desired: [Bookmark] = []
        var seen = Set<String>()
        for conflict in pending.conflicts {
            let candidates: [Bookmark]
            switch resolutions[conflict.id] {
            case .source?: candidates = [conflict.source]
            case .target?: candidates = [conflict.target]
            case .both?: candidates = [conflict.source, conflict.target]
            case nil: return
            }
            for candidate in candidates {
                let snapshot = snapshotForClient(candidate.sourceBrowser.rawValue)
                for node in BookmarkAggregatePlanner.portableChain(of: candidate, in: snapshot)
                    where seen.insert("\(candidate.sourceBrowser.rawValue)|\(node.id)").inserted {
                    desired.append(node)
                }
            }
        }
        guard !desired.isEmpty else { return }

        for browser in pending.propagationTargets where propagationTargets.contains(browser) {
            guard let client = daemon?.connectedClients.first(where: { $0.browser == browser }),
                  mayWriteBookmarks(to: client) else { continue }
            var message = WSMessage(
                type: .sync,
                browser: pending.input.message.browser,
                site: "*",
                category: SyncCategory.bookmarks.rawValue,
                payload: .bookmarks(desired),
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970
            )
            message.isFullMirror = false
            message.targetBookmarkFolder = settings.bookmarkFolder(for: browser)
            _ = stageBrowserBookmarkMutation(message, to: client)
            log("Queued the user-resolved bookmark result for planning into [\(browser.displayName)].")
        }
    }

    private func handleBookmarkPlanContext(_ message: WSMessage, clientId: String) {
        if case .raw(let raw)? = message.payload, let requestId = raw["requestId"]?.value as? String,
           acceptRestoreContext(raw, requestId: requestId, clientId: clientId)
            || acceptSessionBookmarkContext(raw, requestId: requestId, clientId: clientId) {
            return
        }
        guard case .raw(let raw)? = message.payload,
              let requestId = raw["requestId"]?.value as? String,
              let input = pendingNativePlanInputs.removeValue(forKey: requestId),
              input.clientId == clientId else { return }
        guard let token = raw["inputToken"]?.value as? String else {
            log("App refused bookmark planning for [\(clientId)]: \((raw["error"]?.value as? String) ?? "the extension did not provide a valid current-tree token"). Nothing was written.")
            return
        }

        func dictionary(_ value: Any?) -> [String: Any] {
            if let value = value as? [String: Any] { return value }
            if let value = value as? [String: AnyCodable] { return value.mapValues(\.value) }
            return [:]
        }
        func array(_ value: Any?) -> [Any] {
            if let value = value as? [Any] { return value }
            if let value = value as? [AnyCodable] { return value.map(\.value) }
            return []
        }
        let nodes: [Bookmark] = array(raw["nodes"]?.value).compactMap { item in
            let node = dictionary(item)
            guard let id = node["id"] as? String else { return nil }
            let url = node["url"] as? String
            return Bookmark(id: id, title: node["title"] as? String ?? "", url: url,
                            parentId: node["parentId"] as? String,
                            isFolder: (node["isFolder"] as? Bool) ?? (url == nil),
                            sortIndex: node["sortIndex"] as? Int, dateAdded: nil,
                            sourceBrowser: input.browser)
        }
        let roots = dictionary(raw["rootIds"]?.value).compactMapValues { $0 as? String }
        let mapping = dictionary(raw["sourceToNativeIds"]?.value).compactMapValues { $0 as? String }
        let context = BookmarkNativeTreeContext(inputToken: token, browser: input.browser, nodes: nodes,
                                                rootIds: roots, sourceToNativeIds: mapping,
                                                scopeRootId: raw["scopeRootId"]?.value as? String)
        guard BookmarkRestorePlanner.contextMatchesRequestedScope(context, requestedFolder: input.message.targetBookmarkFolder) else {
            log("App refused bookmark planning for [\(clientId)]: it did not report the requested folder as its scope. Nothing was written.")
            return
        }
        _ = backupService?.savePreSyncBackup(
            bookmarks: BookmarkRestorePlanner.archive(of: context),
            sourceBrowser: clientId,
            folderPath: settings.bookmarkFolder(for: input.browser)
        )
        guard case .bookmarks(let desired)? = input.message.payload else { return }
        let plan = input.message.category == Self.removalBatchCategory
            ? NativeBookmarkPlanner.makeRemovalPlan(removals: desired, context: context)
            : NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: input.message.isFullMirror == true)
        guard plan.validationError == nil else {
            log("App refused bookmark planning for [\(clientId)]: \(plan.validationError ?? "invalid target scope").")
            return
        }
        if !plan.conflicts.isEmpty {
            presentBookmarkConflicts(
                PendingBookmarkConflictResolution(input: input, context: context, desired: desired, conflicts: plan.conflicts)
            )
            return
        }
        if input.conflictOnly {
            log("Discarded stable bookmark-divergence check for [\(clientId)]: its live tree no longer has the expected conflict. Nothing was written.")
            return
        }
        guard !plan.operations.isEmpty else {
            if input.message.isExplicitDeletedBookmarkRestore == true,
               let messageId = input.message.messageId,
               let restore = pendingDeletedRestoreByMessageId.removeValue(forKey: messageId) {
                // The fresh native tree already contains the requested item.
                // Treat that independently observed state as verified success
                // and clear only this browser's trash marker.
                backupService?.markDeletedBookmarksRestored(ids: restore.ids, from: restore.browser)
                log("Recently Deleted restore into [\(clientId)] required no write because the current target snapshot already contains it.")
            }
            log("App bookmark plan for [\(clientId)] has no changes; nothing was dispatched.")
            return
        }
        let impact = SafariBookmarkService.WriteImpact(
            added: plan.impact.added, removed: plan.impact.removed, moved: plan.impact.moved,
            modified: plan.impact.modified, total: plan.impact.total,
            signature: plan.impact.signature, destructiveSignature: plan.impact.destructiveSignature
        )
        func reviewNode(_ change: NativeBookmarkChange) -> BookmarkReviewNode {
            let kind: BookmarkReviewNode.Change
            switch change.kind {
            case .added: kind = .added
            case .removed: kind = .removed
            case .moved: kind = .moved
            case .modified: kind = .modified
            }
            return BookmarkReviewNode(id: change.id, title: change.title, url: change.url,
                                      isFolder: change.isFolder, change: kind, children: [],
                                      containingPath: change.containingPath)
        }
        let preview = BookmarkChangePreview(
            before: plan.changes.filter { $0.kind != .added }.map(reviewNode),
            after: plan.changes.filter { $0.kind != .removed }.map(reviewNode)
        )
        guard hasReviewableChanges(preview) else {
            log("Rejected an inconsistent native bookmark plan into [\(clientId)]: its operations had no reviewable rows. Nothing was dispatched.")
            return
        }
        var plannedMessage = input.message
        plannedMessage.category = "bookmark_apply_plan"
        plannedMessage.payload = .raw([
            "inputToken": AnyCodable(plan.inputToken),
            "operations": AnyCodable(plan.operations.map { op in
                ["type": op.kind.rawValue, "id": op.id, "sourceId": op.sourceId as Any, "parentId": op.parentId as Any,
                 "index": op.index as Any, "title": op.title as Any, "url": op.url as Any]
            })
        ])
        let key = "to:" + clientId
        let isExplicitRestore = input.message.isExplicitDeletedBookmarkRestore == true
            || input.message.isExplicitBookmarkRestore == true
        if isExplicitRestore || (!settings.bookmarkSafeMode && !impact.requiresConfirmation) {
            if let client = daemon?.connectedClients.first(where: { $0.id == clientId }) {
                if let messageId = plannedMessage.messageId { dispatchedNativePlans[messageId] = plan.operations }
                daemon?.sendWSMessage(plannedMessage, to: client)
                if isExplicitRestore {
                    log("App dispatched the user-confirmed bookmark restore to [\(clientId)] without a duplicate review; final authorization and result verification remain required.")
                } else {
                    log("App dispatched a non-empty bookmark plan to [\(clientId)] after native planning; Safe Mode is off and the threshold does not require review.")
                }
            }
            return
        }
        pendingBrowserWrites[key] = PendingBrowserWrite(message: plannedMessage, impact: impact,
                                                        preview: preview, settingsFingerprint: bookmarkSettingsFingerprint,
                                                        nativeOperations: plan.operations)
        presentPendingBrowserWrite(key: key)
    }

    private func filterStorageItems(_ items: [StorageItem], clientId: String, policy: WebsiteListPolicy) -> [StorageItem] {
        items.filter { item in
            let origin = item.origin.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let host = URL(string: origin)?.host ?? origin
            let cleanHost = host.starts(with: ".") ? String(host.dropFirst()) : host
            guard !isSystemSyncDisabled(cleanHost) else { return false }

            let siteMatch = settings.websiteSettings.first { site in
                let listed = site.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !listed.isEmpty else { return false }
                let cleanListed = listed.starts(with: ".") ? String(listed.dropFirst()) : listed
                return cleanHost == cleanListed || cleanHost.hasSuffix("." + cleanListed) || cleanListed.hasSuffix("." + cleanHost)
            }
            let isListed = siteMatch != nil

            if policy == .allowList && !isListed { return false }
            if policy == .blockList && isListed { return false }

            let strategy = siteMatch?.strategy ?? settings.browserDataSyncStrategy
            if strategy == .primaryWins {
                let source = siteMatch?.sourceBrowser ?? settings.stateSourceBrowser
                if !clientId.lowercased().starts(with: source.rawValue.lowercased()) {
                    return false // Drop because this client is not the primary source
                }
            }
            return true
        }
    }

    private func filterCookies(
        _ cookies: [SyncCookie],
        clientId: String,
        policy: WebsiteListPolicy,
        acceptingUnchangedSnapshot: Bool = false
    ) -> [SyncCookie] {
        cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDomain = domain.starts(with: ".") ? String(domain.dropFirst()) : domain
            guard !isSystemSyncDisabled(cleanDomain) else { return false }

            let siteMatch = settings.websiteSettings.first { site in
                let listed = site.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !listed.isEmpty else { return false }
                let cleanListed = listed.starts(with: ".") ? String(listed.dropFirst()) : listed
                return cleanDomain == cleanListed || cleanDomain.hasSuffix("." + cleanListed) || cleanListed.hasSuffix("." + cleanDomain)
            }
            let isListed = siteMatch != nil

            if policy == .allowList && !isListed { return false }
            if policy == .blockList && isListed { return false }

            let strategy = siteMatch?.strategy ?? settings.browserDataSyncStrategy
            
            switch strategy {
            case .primaryWins:
                let source = siteMatch?.sourceBrowser ?? settings.stateSourceBrowser
                return clientId.lowercased().starts(with: source.rawValue.lowercased())
            case .latestWins:
                return acceptingUnchangedSnapshot || acceptLatestCookie(cookie, clientId: clientId)
            }
        }
    }

    /// System security exclusions are never overridden by the user-facing site policy.
    private func isSystemSyncDisabled(_ host: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return WebsiteSyncSetting.syncDisabledDomains.contains { domain in
            let normalizedDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedDomain.isEmpty else { return false }
            return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
        }
    }

    private func acceptLatestCookie(_ cookie: SyncCookie, clientId: String) -> Bool {
        let key = cookieVersionKey(cookie)
        let incomingTime = cookie.updatedAt ?? 0
        let isTombstone = cookie.removed == true
        
        if let lastTime = latestCookieVersions[key] {
            let lastClient = latestCookieClients[key] ?? ""
            
            // Tombstones must be STRICTLY newer to win — never win via tie-breaker.
            // On equal timestamps, a live cookie always beats a deletion.
            let wins: Bool
            if isTombstone {
                wins = incomingTime > lastTime
            } else {
                wins = incomingTime > lastTime || (incomingTime == lastTime && clientId > lastClient)
            }
            
            if wins {
                latestCookieVersions[key] = incomingTime
                latestCookieClients[key] = clientId
                if isTombstone {
                    tombstoneWinnerKeys.insert(key)
                    log("🔴 DELETING cookie \(Self.logToken(key)) (Tombstone from [\(clientId)] time \(incomingTime) strictly > last \(lastTime) from [\(lastClient)])")
                } else {
                    // Live cookie wins — if it was previously a tombstone winner, it's a resurrection
                    tombstoneWinnerKeys.remove(key)
                    log("🟢 ACCEPTING cookie \(Self.logToken(key)) (Update from [\(clientId)] time \(incomingTime) > last \(lastTime) from [\(lastClient)])")
                }
                return true
            }
            
            if isTombstone {
                log("⚪️ DROPPING Tombstone for cookie \(Self.logToken(key)) from [\(clientId)] (time \(incomingTime) NOT > last \(lastTime) from [\(lastClient)], live cookie wins)")
            } else {
                log("⚪️ DROPPING Update for cookie \(Self.logToken(key)) from [\(clientId)] (time \(incomingTime) <= last \(lastTime) from [\(lastClient)])")
            }
            return false
        }
        
        // First time we see this key
        latestCookieVersions[key] = incomingTime
        latestCookieClients[key] = clientId
        if isTombstone {
            tombstoneWinnerKeys.insert(key)
            log("🔴 DELETING cookie \(Self.logToken(key)) (Tombstone from [\(clientId)] accepted as first seen. Time: \(incomingTime))")
        }
        return true
    }

    private func logCookieDomains(_ cookies: [SyncCookie], clientId: String) {
        guard !cookies.isEmpty else { return }
        let domains = Dictionary(grouping: cookies) { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return domain.starts(with: ".") ? String(domain.dropFirst()) : domain
        }
        // Sites and cookie names are browsing data; the log keeps counts only.
        log("Accepted \(cookies.count) cookies for \(domains.count) sites from [\(clientId)]")
    }

    /// A short token so one cookie can be followed through the log without
    /// writing its site or name to disk. Salted per install, so common cookie
    /// names cannot be recovered by hashing a dictionary of them.
    private static func logToken(_ value: String) -> String {
        SHA256.hash(data: Data((logTokenSalt + value).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static let logTokenSalt: String = {
        let key = "BrowSyncLogTokenSalt"
        if let salt = UserDefaults.standard.string(forKey: key) { return salt }
        let salt = UUID().uuidString
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }()

    private func cookieVersionKey(_ cookie: SyncCookie) -> String {
        var domain = cookie.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize: strip leading dot so ".ct106.cc" and "ct106.cc" share the same key
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        return "\(domain)::\(path)::\(cookie.name)"
    }

    private func isClient(_ clientId: String, from browser: Browser) -> Bool {
        let clientBrowserId = clientId.components(separatedBy: "-").first?.lowercased() ?? clientId.lowercased()
        return clientBrowserId == browser.id.lowercased()
    }

    private func buildDeletedBookmarkForest(from deletedBms: [Bookmark], sourceBrowser: String) -> [DeletedBookmark] {
        var nodeDict = [String: DeletedBookmark]()
        let now = Date()
        
        for b in deletedBms {
            nodeDict[b.id] = DeletedBookmark(id: b.id, title: b.title, url: b.url?.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, deletedAt: now, sourceBrowser: sourceBrowser, children: nil)
        }
        
        var roots = [DeletedBookmark]()
        let allIds = Set(deletedBms.map { $0.id })
        
        let rootIds = deletedBms.filter {
            guard let pid = $0.parentId else { return true }
            return !allIds.contains(pid)
        }.map { $0.id }
        
        func buildTree(for id: String) -> DeletedBookmark? {
            guard var node = nodeDict[id] else { return nil }
            let children = deletedBms.filter { $0.parentId == id }
            if !children.isEmpty {
                node.children = children.compactMap { buildTree(for: $0.id) }
            }
            return node
        }
        
        for rootId in rootIds {
            if let rootNode = buildTree(for: rootId) {
                roots.append(rootNode)
            }
        }
        
        return roots
    }

    private func bookmarkURL(_ bookmark: Bookmark) -> String? {
        bookmark.url.flatMap { $0 }
    }

    /// Summarize an accepted source snapshot change for automatic-sync UI.
    private func populateAutomaticBookmarkChangeStats(
        previous: [Bookmark], current: [Bookmark], stats: inout SyncStats,
        ignoringSafariEchoFor clientId: String? = nil
    ) {
        var echoedIDs = Set<String>()
        if let clientId, let push = recentSafariPushByClient[clientId] {
            if Date().timeIntervalSince(push.sentAt) <= 30 {
                let expectedByID = Dictionary(push.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for item in current {
                    if let expected = expectedByID[item.id],
                       item.title == expected.title, item.url == expected.url,
                       (item.parentId == expected.parentId || item.parentId == previousByID[item.id]?.parentId) {
                        echoedIDs.insert(item.id)
                    }
                }
            } else {
                recentSafariPushByClient.removeValue(forKey: clientId)
            }
        }
        let previous = previous.filter { !echoedIDs.contains($0.id) }
        let current = current.filter { !echoedIDs.contains($0.id) }
        func isSystemRoot(_ bookmark: Bookmark) -> Bool {
            let id = bookmark.id.lowercased()
            return ["0", "1", "2", "3"].contains(id) ||
                (id.hasPrefix("firefox-") && id.hasSuffix("-root")) ||
                id.hasPrefix("browsync-root-")
        }

        func parentPaths(in tree: [Bookmark]) -> [String: String] {
            let byID = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var cache: [String: String] = [:]
            func path(for bookmark: Bookmark, visited: Set<String> = []) -> String {
                if let cached = cache[bookmark.id] { return cached }
                if isSystemRoot(bookmark) {
                    // Native roots are often not included in browser payloads.
                    // Retain their semantic identity so a cross-root move can
                    // still be reported without relying on an unstable UUID.
                    let root: String
                    switch bookmark.id.lowercased() {
                    case "1", "browsync-root-bar": root = "bookmarks-bar"
                    case "2", "browsync-root-other": root = "other-bookmarks"
                    case "3", "browsync-root-mobile": root = "mobile-bookmarks"
                    default: root = "root"
                    }
                    cache[bookmark.id] = root
                    return root
                }
                guard !visited.contains(bookmark.id) else { return bookmark.title }
                let parentPath: String
                if let parentID = bookmark.parentId {
                    if let parent = byID[parentID] {
                        parentPath = path(for: parent, visited: visited.union([bookmark.id]))
                    } else {
                        // Browser payloads often omit native root nodes. Known
                        // IDs still identify the three standard roots; unknown
                        // IDs deliberately collapse to one neutral root instead
                        // of creating a false-positive move.
                        switch parentID {
                        case "1": parentPath = "bookmarks-bar"
                        case "2": parentPath = "other-bookmarks"
                        case "3": parentPath = "mobile-bookmarks"
                        default: parentPath = "root"
                        }
                    }
                } else {
                    parentPath = "root"
                }
                let result = "\(parentPath)/\(bookmark.title)"
                cache[bookmark.id] = result
                return result
            }
            return Dictionary(uniqueKeysWithValues: tree.map { bookmark in
                let parentPath: String
                if let parentID = bookmark.parentId, let parent = byID[parentID] {
                    parentPath = path(for: parent)
                } else if let parentID = bookmark.parentId {
                    switch parentID {
                    case "1": parentPath = "bookmarks-bar"
                    case "2": parentPath = "other-bookmarks"
                    case "3": parentPath = "mobile-bookmarks"
                    default: parentPath = "root"
                    }
                } else {
                    parentPath = "root"
                }
                return (bookmark.id, parentPath)
            })
        }

        /// Moving one item shifts the numeric index of its siblings. Compare
        /// the relative order instead, so only the item that actually moved is
        /// reported as adjusted. With unique keys, the unchanged items form a
        /// longest increasing subsequence of their old positions.
        func reorderedKeys(
            previous: [Bookmark],
            current: [Bookmark],
            previousParents: [String: String],
            currentParents: [String: String],
            key: (Bookmark) -> String?
        ) -> Set<String> {
            func orderedKeys(in tree: [Bookmark], parents: [String: String]) -> [String: [String]] {
                var entries: [String: [(key: String, order: Int, position: Int)]] = [:]
                var seen = Set<String>()
                for (position, bookmark) in tree.enumerated() {
                    guard let itemKey = key(bookmark), seen.insert(itemKey).inserted,
                          let parent = parents[bookmark.id] else { continue }
                    entries[parent, default: []].append((itemKey, bookmark.sortIndex ?? position, position))
                }
                return entries.mapValues { values in
                    values.sorted {
                        $0.order == $1.order ? $0.position < $1.position : $0.order < $1.order
                    }.map(\.key)
                }
            }

            let oldByParent = orderedKeys(in: previous, parents: previousParents)
            let newByParent = orderedKeys(in: current, parents: currentParents)
            var changed = Set<String>()
            for parent in Set(oldByParent.keys).intersection(newByParent.keys) {
                guard let old = oldByParent[parent], let new = newByParent[parent] else { continue }
                let oldPositions = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element, $0.offset) })
                let sharedNew = new.filter { oldPositions[$0] != nil }
                guard sharedNew.count > 1 else { continue }

                var tails: [Int] = []
                var tailIndices: [Int] = []
                var predecessors = Array(repeating: -1, count: sharedNew.count)
                for (index, itemKey) in sharedNew.enumerated() {
                    guard let position = oldPositions[itemKey] else { continue }
                    var low = 0
                    var high = tails.count
                    while low < high {
                        let middle = (low + high) / 2
                        if tails[middle] < position { low = middle + 1 } else { high = middle }
                    }
                    if low > 0 { predecessors[index] = tailIndices[low - 1] }
                    if low == tails.count {
                        tails.append(position)
                        tailIndices.append(index)
                    } else {
                        tails[low] = position
                        tailIndices[low] = index
                    }
                }
                var unchanged = Set<String>()
                var index = tailIndices.last ?? -1
                while index >= 0 {
                    unchanged.insert(sharedNew[index])
                    index = predecessors[index]
                }
                changed.formUnion(Set(sharedNew).subtracting(unchanged))
            }
            return changed
        }

        let previousBookmarks = Dictionary(
            previous.compactMap { bookmark in bookmarkURL(bookmark).map { ($0.lowercased(), bookmark) } },
            uniquingKeysWith: { first, _ in first }
        )
        let currentBookmarks = Dictionary(
            current.compactMap { bookmark in bookmarkURL(bookmark).map { ($0.lowercased(), bookmark) } },
            uniquingKeysWith: { first, _ in first }
        )
        let previousParentPaths = parentPaths(in: previous)
        let currentParentPaths = parentPaths(in: current)
        // Sibling order is browser-owned presentation state. It is neither a
        // synchronization operation nor an automatic-sync notification.
        let reorderedBookmarks: Set<String> = []
        // A newly present URL is non-destructive and can be reported safely.
        // Missing URLs are intentionally *not* inferred as removals here: a
        // browser may expose a transient or partial tree while it is writing.
        let previousByID = Dictionary(previous.filter { !$0.isFolder }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stats.bookmarksAdded = currentBookmarks.values.filter { item in
            previousByID[item.id] == nil && !previousBookmarks.keys.contains(bookmarkURL(item)?.lowercased() ?? "")
        }.count
        stats.bookmarksModified = Set(currentBookmarks.keys).intersection(previousBookmarks.keys).reduce(into: 0) { count, url in
            guard let old = previousBookmarks[url], let new = currentBookmarks[url] else { return }
            let reordered = reorderedBookmarks.contains(url)
            let moved = previousParentPaths[old.id] != currentParentPaths[new.id]
            if old.title != new.title || reordered || moved { count += 1 }
        }
        stats.bookmarksModified += currentBookmarks.values.reduce(into: 0) { count, item in
            guard let old = previousByID[item.id], old.url != item.url else { return }
            count += 1
        }

        let previousFolders = Dictionary(
            previous.filter { $0.isFolder && !isSystemRoot($0) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentFolders = Dictionary(
            current.filter { $0.isFolder && !isSystemRoot($0) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousFolderLocations = Set(previousFolders.values.compactMap { folder -> String? in
            previousParentPaths[folder.id].map { "\($0)/\(folder.title)" }
        })
        // An unknown folder ID at a previously unseen location is a safe add.
        // Do not turn a missing folder into a deletion from a full snapshot.
        stats.bookmarkFoldersAdded = currentFolders.values.reduce(into: 0) { count, folder in
            guard previousFolders[folder.id] == nil,
                  let parentPath = currentParentPaths[folder.id],
                  !previousFolderLocations.contains("\(parentPath)/\(folder.title)")
            else { return }
            count += 1
        }
        let reorderedFolders: Set<String> = []
        stats.bookmarkFoldersModified = Set(currentFolders.keys).intersection(previousFolders.keys).reduce(into: 0) { count, id in
            guard let old = previousFolders[id], let new = currentFolders[id] else { return }
            let reordered = reorderedFolders.contains(id)
            let moved = previousParentPaths[old.id] != currentParentPaths[new.id]
            if old.title != new.title || reordered || moved { count += 1 }
        }
    }

    private func folderKey(_ bookmark: Bookmark) -> String {
        "\(bookmark.parentId ?? "")|\(bookmark.title.lowercased())"
    }

    private func isBrowserMobileRoot(_ bookmark: Bookmark) -> Bool {
        guard bookmark.isFolder, bookmarkURL(bookmark) == nil else { return false }
        let id = bookmark.id.lowercased()
        return bookmark.id == "3" || id.hasPrefix("mobile")
    }

    private func sanitizeIncomingBookmarksForSafari(_ bookmarks: [Bookmark], from clientId: String) -> [Bookmark] {
        guard !clientId.lowercased().contains("safari") else { return bookmarks }

        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        let browser = Browser(rawValue: browserId)

        // A bookmark the user manually restored still matches its old tombstone
        // (matched by URL/title, not id) for up to 24h, which would otherwise
        // silently strip it back out of every incoming sync as "still deleted".
        if let browser {
            backupService?.resurrectDeletedBookmarks(seenIn: bookmarks, browser: browser)
        }

        let rootIds = Set(["0", "1", "2", "3"])
        let bookmarksById = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childrenByParent = Dictionary(grouping: bookmarks, by: { $0.parentId ?? "" })
        let selectedFolderIds: Set<String> = {
            guard let browser, let folder = settings.bookmarkFolder(for: browser) else { return [] }
            return BookmarkTreeMerger.idsInFolderIncludingRoot(tree: bookmarks, folderPath: folder)
        }()
        // Only the selected folder node itself is structural scope. Its
        // descendants are data and must still be filtered by newer deletion
        // tombstones. Treating every descendant as a scope node resurrected
        // stale copies from another browser after the user deleted them.
        let selectedFolderRootIds = Set(selectedFolderIds.filter { id in
            guard let bookmark = bookmarksById[id] else { return false }
            guard let parentId = bookmark.parentId else { return true }
            return !selectedFolderIds.contains(parentId)
        })

        func deletedSignatures(from items: [DeletedBookmark]) -> (folders: Set<String>, urls: Set<String>) {
            var folderSignatures = Set<String>()
            var urls = Set<String>()
            let recentCutoff = Date().addingTimeInterval(-24 * 60 * 60)

            func visit(_ item: DeletedBookmark) {
                if item.deletedAt >= recentCutoff {
                    if item.isFolder, item.url == nil {
                        let parent = item.parentId ?? ""
                        folderSignatures.insert("\(parent)|\(item.title.lowercased())")
                    } else if let url = item.url?.lowercased() {
                        urls.insert(url)
                    }
                }
                item.children?.forEach(visit)
            }

            items.forEach(visit)
            return (folderSignatures, urls)
        }

        let deleted = deletedSignatures(from: backupService?.deletedBookmarks ?? [])

        func isDeletedByTombstone(_ bookmark: Bookmark) -> Bool {
            if bookmark.isFolder, bookmarkURL(bookmark) == nil {
                let parent = bookmark.parentId ?? ""
                return deleted.folders.contains("\(parent)|\(bookmark.title.lowercased())")
            }
            if let url = bookmarkURL(bookmark)?.lowercased() {
                return deleted.urls.contains(url)
            }
            return false
        }

        func shouldDropNode(_ bookmark: Bookmark) -> Bool {
            if rootIds.contains(bookmark.id) { return true }
            if isBrowserMobileRoot(bookmark) { return true }
            if !selectedFolderRootIds.contains(bookmark.id), isDeletedByTombstone(bookmark) { return true }
            return false
        }

        func shouldDropDescendants(of bookmark: Bookmark) -> Bool {
            if selectedFolderRootIds.contains(bookmark.id) { return false }
            return bookmark.id == "0" ||
            bookmark.id == "3" ||
            isBrowserMobileRoot(bookmark) ||
            isDeletedByTombstone(bookmark)
        }

        var excludedIds = Set(bookmarks.filter(shouldDropNode).map(\.id))
        var queue = bookmarks.filter(shouldDropDescendants).map(\.id)
        while let current = queue.popLast() {
            for child in childrenByParent[current] ?? [] {
                if excludedIds.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }

        guard !excludedIds.isEmpty else { return bookmarks }

        return bookmarks.filter { bookmark in
            if excludedIds.contains(bookmark.id) { return false }
            if let parentId = bookmark.parentId, excludedIds.contains(parentId) { return false }
            if let parentId = bookmark.parentId, let parent = bookmarksById[parentId], shouldDropDescendants(of: parent) { return false }
            return true
        }
    }

    // MARK: - Persistence

    private func persist(payload: WSPayload, category: String, from clientId: String, isFullMirror: Bool = false) {
        switch payload {
        case .bookmarks(let bookmarks):
            let targetDir = dataDir.appendingPathComponent("bookmarks")
            if category == "bookmarks" || category == "bookmark_backup" {
                save(bookmarks, to: targetDir.appendingPathComponent("\(clientId).json"))
                // Update bookmark count for this browser
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                bookmarkCounts[browserId] = bookmarks.count
            }
            // Bookmark payloads are observations only. Safari is written
            // exclusively by sync sessions (scoped native plan + verification).
        case .history(let entries):
            let histDir = dataDir.appendingPathComponent("history")
            save(entries, to: histDir.appendingPathComponent("\(clientId).json"))
        default:
            // For storage/cookie sync, not persisting to disk in MVP
            break
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomicWrite)
        } catch {
            logger.error("Failed to save sync data: \(error)")
        }
    }

    /// Raw sync payloads may contain cookies and storage values. They are never
    /// persisted in normal operation; remove diagnostic payloads left by older builds.
    private func removeLegacyPayloadLogs() {
        let fileManager = FileManager.default
        for payloadDir in managedPayloadLogDirectories() {
            let logDir = payloadDir.deletingLastPathComponent()
            var pendingRemovalDirs = (try? fileManager.contentsOfDirectory(
                at: logDir,
                includingPropertiesForKeys: nil,
                options: []
            ))?.filter { $0.lastPathComponent.hasPrefix(".payloads-deleting-") } ?? []

            if fileManager.fileExists(atPath: payloadDir.path) {
            // Renaming within the same directory is immediate, even when a legacy
            // payload directory contains many thousands of files. The UI can start
            // without waiting for recursive deletion to finish.
                let pendingRemovalDir = logDir.appendingPathComponent(
                    ".payloads-deleting-\(UUID().uuidString)"
                )
                do {
                    try fileManager.moveItem(at: payloadDir, to: pendingRemovalDir)
                    pendingRemovalDirs.append(pendingRemovalDir)
                    log("Scheduled removal of legacy raw payload logs at \(payloadDir.path).")
                } catch {
                    log("Failed to schedule legacy raw payload log removal: \(error.localizedDescription)")
                }
            }

            for pendingRemovalDir in pendingRemovalDirs {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        try FileManager.default.removeItem(at: pendingRemovalDir)
                        DispatchQueue.main.async {
                            self?.log("Removed legacy raw payload logs at \(pendingRemovalDir.path).")
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.log("Failed to remove legacy raw payload logs: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func managedPayloadLogDirectories() -> [URL] {
        managedLogDirectories().map { $0.appendingPathComponent("payloads") }
    }

    private func managedLogDirectories() -> [URL] {
        let current = dataDir.appendingPathComponent("logs")
        let actualUserHome = NSHomeDirectoryForUser(NSUserName()).map(URL.init(fileURLWithPath:))
        let containerHome = FileManager.default.homeDirectoryForCurrentUser
        let candidateHomes = [actualUserHome, containerHome].compactMap { $0 }
        let legacyContainerLogs = candidateHomes.map {
            $0.appendingPathComponent("Library/Containers/com.ct106.browsync/Data/Library/Application Support/BrowSync/logs")
        }
        return ([current] + legacyContainerLogs).reduce(into: []) { directories, directory in
            if !directories.contains(where: { $0.standardizedFileURL == directory.standardizedFileURL }) {
                directories.append(directory)
            }
        }
    }

    /// Text logs are small daily files; clean them deterministically after app
    /// initialization rather than relying on an unobserved background task.
    private func pruneManagedSyncLogs() {
        for logDir in managedLogDirectories() {
            Self.pruneSyncLogs(
                in: logDir,
                retention: Self.syncLogRetention,
                maximumBytes: Self.syncLogMaximumBytes
            )
        }
    }

    nonisolated private static func pruneSyncLogs(
        in logDir: URL,
        retention: TimeInterval,
        maximumBytes: Int
    ) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct LogFile {
            let url: URL
            let modifiedAt: Date
            let size: Int
        }

        let cutoff = Date().addingTimeInterval(-retention)
        var retained: [LogFile] = []
        for url in urls where url.pathExtension == "log" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            let file = LogFile(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0
            )
            if file.modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: file.url)
            } else {
                retained.append(file)
            }
        }

        var totalBytes = retained.reduce(0) { $0 + $1.size }
        for file in retained.sorted(by: { $0.modifiedAt < $1.modifiedAt }) where totalBytes > maximumBytes {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            totalBytes -= file.size
        }
    }

    // MARK: - Log

    /// Logs a browser's bookmark root layout (IDs, roles, counts only). A change
    /// here explains otherwise baffling syncs, e.g. Chrome moving to account roots.
    private func logBookmarkRoots(_ message: WSMessage, clientId: String) {
        guard case .raw(let raw) = message.payload,
              let roots = raw["roots"]?.value as? [Any] else { return }
        let safe = { (value: Any?) -> String in
            String(String(describing: value ?? "?").filter { $0.isLetter || $0.isNumber || "-_".contains($0) }.prefix(32))
        }
        let summary = roots.compactMap { $0 as? [String: Any] }.map { root in
            let syncing = (root["syncing"] as? Bool) == true ? "account" : "local"
            return "\(safe(root["type"])) id=\(safe(root["id"])) role=\(safe(root["role"])) \(syncing) children=\(safe(root["children"]))"
        }.joined(separator: "; ")
        let changed = raw["previous"]?.value is String
        log("Bookmark roots \(changed ? "changed" : "reported") from [\(clientId)]: \(summary)")
    }

    func log(_ message: String) {
        let entry = SyncLogEntry(date: Date(), message: message)
        syncLog.append(entry)
        logger.info("\(message)")

        // Persist log line
        let logDir = dataDir.appendingPathComponent("logs")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: entry.date)
        let logFile = logDir.appendingPathComponent("sync-\(dateString).log")
        let line = "[\(ISO8601DateFormatter().string(from: entry.date))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Internal Write
    
    func recordInternalWrite() {
        self.lastNetworkSyncTime = Date()
    }
}

// MARK: - Aggregate bookmark sync sessions

extension SyncService {
    /// Automatic triggers (a new snapshot from any browser) are coalesced so
    /// that changes made in several browsers land in one session.
    func scheduleBookmarkSyncSession(after delay: TimeInterval = 2) {
        let isPro = AppState.shared.purchaseService.isProUnlocked
        guard isPro, settings.bookmarkAutoSync, settings.enabledCategories.contains(.bookmarks) else { return }
        if bookmarkSyncSession != nil {
            bookmarkSessionNeedsRerun = true
            return
        }
        bookmarkSessionScheduleTask?.cancel()
        bookmarkSessionScheduleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.startBookmarkSyncSession(manual: false) }
        }
    }

    /// Detects every participant's local changes, collects one current native
    /// tree per writable target and plans all of them together.
    func startBookmarkSyncSession(manual: Bool) {
        guard settings.enabledCategories.contains(.bookmarks) else { return }
        bookmarkSessionScheduleTask?.cancel()
        if let existing = bookmarkSyncSession {
            guard manual, existing.phase == .collecting || existing.phase == .reviewing else {
                bookmarkSessionNeedsRerun = true
                return
            }
            // A manual sync recomputes everything from the persisted
            // baselines; the stale review is discarded, not remembered.
            discardBookmarkSyncSession(reason: "a new manual sync started")
        }
        bookmarkSessionNeedsRerun = false

        let participants = settings.bookmarkParticipatingBrowsers.sorted { $0.rawValue < $1.rawValue }
        guard participants.count > 1 else { return }
        var session = BookmarkSyncSession(manual: manual, settingsFingerprint: bookmarkSettingsFingerprint)
        for browser in participants {
            if let latest = backupService?.getRecentSnapshots(sourceBrowser: browser.rawValue, limit: 1).last {
                session.observed[browser] = latest.bookmarks
            }
        }
        let sources = participants.filter { browser in
            settings.bookmarkSyncStrategy == .twoWayMerge || browser == settings.bookmarkSourceBrowser
        }
        let targets = participants.filter { BookmarkWritePolicy.allowsWrite(to: $0, settings: settings) }
        for source in sources {
            guard let current = session.observed[source] else { continue }
            for target in targets where target != source {
                let baseline = syncBaseline(source: source, target: target, current: current)
                let delta = BookmarkSnapshotDiffer.ignoringIdentityDrift(BookmarkSnapshotDiffer.diff(
                    older: BookmarkSnapshotRecord(id: "baseline", capturedAt: .distantPast, sourceBrowser: source.rawValue, bookmarks: baseline),
                    newer: BookmarkSnapshotRecord(id: "current", capturedAt: Date(), sourceBrowser: source.rawValue, bookmarks: current)
                ))
                if !delta.isEmpty {
                    session.deltas[BookmarkSyncSession.pairKey(source, target)] = delta
                    session.baselines[BookmarkSyncSession.pairKey(source, target)] = baseline
                }
            }
        }

        var stable: [BookmarkSyncConflict] = []
        if settings.bookmarkSyncStrategy == .twoWayMerge {
            // A bookmark with a pending change (for example a rename not yet
            // synchronized) naturally differs between browsers; that is an
            // ordinary change, not a stable conflict.
            let pending = pendingBookmarkURLs(session)
            stable = BookmarkAggregatePlanner.stableConflicts(snapshots: session.observed).filter { conflict in
                conflict.versions.map(\.bookmark).allSatisfy { node in
                    BookmarkSyncConflict.canonicalURL(node.url).map { !pending.contains($0) } ?? true
                }
            }
        }
        session.conflicts = stable
        // Even without a detected change, the live trees are collected:
        // reconciliation recovers differences whose snapshots were missed.

        // Every writable target is read: a conflict choice can require a write
        // into a browser that received no ordinary change in this session.
        for target in targets {
            if target == .safari {
                guard SandboxAccessManager.shared.hasSafariAccess else {
                    log("Bookmark sync skipped Safari as a target: no folder access granted yet.")
                    continue
                }
                let read = safariBookmarks.nativePlanContext(folderPath: settings.bookmarkFolder(for: .safari))
                if let context = read.context {
                    session.contexts[.safari] = context
                } else {
                    if let folder = settings.bookmarkFolder(for: .safari), !folder.isEmpty { markMissingBookmarkFolder(.safari, folder: folder) }
                    log("Bookmark sync skipped Safari as a target: \(read.error ?? "its tree is unavailable"). Nothing will be written there.")
                }
                continue
            }
            guard let client = daemon?.connectedClients.first(where: { $0.browser == target }), mayWriteBookmarks(to: client) else {
                log("Bookmark sync skipped \(target.displayName) as a target: it is not connected with a current extension. Its changes stay pending.")
                continue
            }
            let requestId = UUID().uuidString
            session.awaitingContexts[requestId] = target
            session.clientIds[target] = client.id
            let request = WSMessage(type: .pull, site: requestId, category: "bookmark_plan_context",
                                    payload: .raw(["requestId": AnyCodable(requestId),
                                                   "targetFolder": AnyCodable(settings.bookmarkFolder(for: target) ?? NSNull())]),
                                    messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
            daemon?.sendBookmarkControlMessage(request, to: client)
        }
        bookmarkSyncSession = session
        log("Bookmark sync detected \(session.deltas.count) changed source→target pair(s) and \(stable.count) existing conflict(s); collecting \(session.awaitingContexts.count) browser tree(s).")
        if session.awaitingContexts.isEmpty {
            planBookmarkSyncSession()
        } else {
            let id = session.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run {
                    guard let self, var session = self.bookmarkSyncSession, session.id == id, session.phase == .collecting,
                          !session.awaitingContexts.isEmpty else { return }
                    let missing = Set(session.awaitingContexts.values).map(\.displayName).sorted().joined(separator: ", ")
                    session.awaitingContexts.removeAll()
                    self.bookmarkSyncSession = session
                    self.log("Bookmark sync continued without \(missing): no current tree arrived in time. Changes for it stay pending.")
                    self.planBookmarkSyncSession()
                }
            }
        }
    }

    /// Returns true when the context answered the current session.
    func acceptSessionBookmarkContext(_ raw: [String: AnyCodable], requestId: String, clientId: String) -> Bool {
        guard var session = bookmarkSyncSession, let target = session.awaitingContexts[requestId] else { return false }
        session.awaitingContexts.removeValue(forKey: requestId)
        if session.clientIds[target] == clientId, let context = nativeTreeContext(from: raw, browser: target),
           BookmarkRestorePlanner.contextMatchesRequestedScope(context, requestedFolder: settings.bookmarkFolder(for: target)) {
            session.contexts[target] = context
            _ = backupService?.savePreSyncBackup(bookmarks: BookmarkRestorePlanner.archive(of: context), sourceBrowser: clientId,
                                                 folderPath: settings.bookmarkFolder(for: target))
        } else {
            log("Bookmark sync skipped [\(clientId)] as a target: \((raw["error"]?.value as? String) ?? "it returned no valid current tree"). Nothing will be written there.")
            if let folder = settings.bookmarkFolder(for: target), !folder.isEmpty, raw["error"] != nil {
                markMissingBookmarkFolder(target, folder: folder)
            }
        }
        bookmarkSyncSession = session
        if session.phase == .collecting && session.awaitingContexts.isEmpty { planBookmarkSyncSession() }
        return true
    }

    func nativeTreeContext(from raw: [String: AnyCodable], browser: Browser) -> BookmarkNativeTreeContext? {
        guard let token = raw["inputToken"]?.value as? String else { return nil }
        func dictionary(_ value: Any?) -> [String: Any] {
            if let value = value as? [String: Any] { return value }
            if let value = value as? [String: AnyCodable] { return value.mapValues(\.value) }
            return [:]
        }
        func array(_ value: Any?) -> [Any] {
            if let value = value as? [Any] { return value }
            if let value = value as? [AnyCodable] { return value.map(\.value) }
            return []
        }
        let nodes: [Bookmark] = array(raw["nodes"]?.value).compactMap { item in
            let node = dictionary(item)
            guard let id = node["id"] as? String else { return nil }
            let url = node["url"] as? String
            return Bookmark(id: id, title: node["title"] as? String ?? "", url: url,
                            parentId: node["parentId"] as? String,
                            isFolder: (node["isFolder"] as? Bool) ?? (url == nil),
                            sortIndex: node["sortIndex"] as? Int, dateAdded: nil,
                            sourceBrowser: browser)
        }
        return BookmarkNativeTreeContext(
            inputToken: token, browser: browser, nodes: nodes,
            rootIds: dictionary(raw["rootIds"]?.value).compactMapValues { $0 as? String },
            sourceToNativeIds: dictionary(raw["sourceToNativeIds"]?.value).compactMapValues { $0 as? String },
            scopeRootId: raw["scopeRootId"]?.value as? String)
    }

    /// The prepared contribution of every source into `target`.
    private func sessionContributions(_ session: BookmarkSyncSession, target: Browser) -> [BookmarkSourceContribution] {
        session.observed.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { source in
            guard source != target, let current = session.observed[source] else { return nil }
            let key = BookmarkSyncSession.pairKey(source, target)
            let delta = session.deltas[key]
            var payload = delta.map { BookmarkSnapshotDiffer.payload(for: $0, current: current) } ?? []
            for node in session.reconciliation.additions[key] ?? [] where !payload.contains(where: { $0.id == node.id }) {
                payload.append(node)
            }
            var removals = delta?.removed ?? []
            for node in session.reconciliation.removals[key] ?? [] where !removals.contains(where: { $0.id == node.id }) {
                removals.append(node)
            }
            guard !payload.isEmpty || !removals.isEmpty else { return nil }
            return BookmarkSourceContribution(
                source: source,
                desired: bookmarksPreparedForTarget(payload, sourceBrowser: source, targetBrowser: target),
                removals: removals)
        }
    }

    private func planBookmarkSyncSession() {
        guard var session = bookmarkSyncSession, session.phase == .collecting else { return }
        guard session.settingsFingerprint == bookmarkSettingsFingerprint else {
            discardBookmarkSyncSession(reason: "bookmark sync settings changed")
            return
        }
        if settings.bookmarkSyncStrategy == .twoWayMerge {
            session.reconciliation = reconcileLiveTrees(session)
            if !session.reconciliation.isEmpty {
                let added = session.reconciliation.additions.values.reduce(0) { $0 + $1.filter { !$0.isFolder }.count }
                let removed = session.reconciliation.removals.values.reduce(0) { $0 + $1.count }
                log("Reconciliation found \(added) missed addition(s) and \(removed) missed deletion(s) across browsers.")
            }
        }
        recordDetectedBookmarkDeletions(session)
        session.ignored = ignoredBookmarkChanges
        var conflicts = session.conflicts
        var plans: [Browser: BookmarkTargetPlan] = [:]
        // Conflicts found in one target are excluded everywhere, so iterate
        // until every target was planned against the complete conflict set.
        for _ in 0..<4 {
            plans = [:]
            var found = false
            for (target, context) in session.contexts {
                let plan = BookmarkAggregatePlanner.plan(target: target, context: context,
                                                         contributions: sessionContributions(session, target: target),
                                                         conflicts: conflicts)
                for conflict in plan.conflicts {
                    if !conflicts.contains(where: { $0.id == conflict.id }) { found = true }
                    BookmarkAggregatePlanner.append(conflict, to: &conflicts)
                }
                plans[target] = plan
            }
            if !found { break }
        }
        session.conflicts = conflicts
        session.rawPlans = plans
        session.plans = plans.mapValues { BookmarkIgnore.filtered($0, ignored: session.ignored) }
        plans = session.plans
        let activeConflicts = conflicts.filter { !session.ignored.contains(BookmarkIgnore.conflictKey($0.id)) }
        for plan in plans.values {
            for route in plan.routes where route.validationError != nil {
                log("Bookmark plan \(route.source?.displayName ?? "?") → \(plan.target.displayName) was refused: \(route.validationError ?? ""). Those changes stay pending.")
            }
        }

        let hasOperations = plans.values.contains { !$0.operations.isEmpty }
        guard hasOperations || !activeConflicts.isEmpty else {
            log("Bookmark sync: every browser already contains the detected changes; nothing needs to be written.")
            session.phase = .applying
            bookmarkSyncSession = session
            completeBookmarkSessionWrites()
            return
        }
        let needsReview = settings.bookmarkSafeMode || !activeConflicts.isEmpty || plans.contains { target, plan in
            let destructive = plan.operations.filter { $0.kind != .create }.count
            let total = session.contexts[target]?.nodes.count ?? 0
            return destructive > max(8, total / 20)
        }
        if !needsReview {
            session.phase = .applying
            bookmarkSyncSession = session
            log("Bookmark sync applies the plan directly: Safe Mode is off and no target crosses the large-change threshold.")
            applyBookmarkSyncSession(selection: nil, choices: [:])
            return
        }
        session.phase = .reviewing
        bookmarkSyncSession = session
        publishPendingReviews()
        presentBookmarkSyncSessionReview(activate: true)
        if !session.manual {
            let totals = plans.values.flatMap(\.operations)
            AppState.shared.notificationService.notifyBookmarkChangesAwaitingReview(
                source: "BrowSync", target: plans.keys.map(\.displayName).sorted().joined(separator: ", "),
                clientId: Self.bookmarkSessionReviewKey,
                added: totals.filter { $0.kind == .create }.count,
                removed: totals.filter { $0.kind == .removeTree }.count,
                moved: totals.filter { $0.kind == .move }.count,
                modified: totals.filter { $0.kind == .update }.count,
                isLarge: !settings.bookmarkSafeMode && activeConflicts.isEmpty)
        }
    }

    static func sessionRouteId(_ target: Browser) -> String {
        "\(bookmarkSessionReviewKey)|\(target.rawValue)"
    }

    /// One group per target browser; changes from every source are listed
    /// together. Conflicts form their own group because they span browsers.
    var bookmarkSyncSessionRoutes: [BookmarkReviewRoute] {
        guard let session = bookmarkSyncSession else { return [] }
        func reviewNode(_ change: NativeBookmarkChange) -> BookmarkReviewNode {
            let kind: BookmarkReviewNode.Change
            switch change.kind {
            case .added: kind = .added
            case .removed: kind = .removed
            case .moved: kind = .moved
            case .modified: kind = .modified
            }
            return BookmarkReviewNode(id: change.id, title: change.title, url: change.url, isFolder: change.isFolder,
                                      change: kind, children: [], containingPath: change.containingPath)
        }
        var routes: [BookmarkReviewRoute] = []
        for target in session.plans.keys.sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
            guard let plan = session.plans[target] else { continue }
            let changes = plan.routes.flatMap(\.changes)
            let operations = plan.routes.flatMap(\.operations)
            guard !operations.isEmpty, !changes.isEmpty else { continue }
            let impact = SafariBookmarkService.WriteImpact(
                added: operations.filter { $0.kind == .create }.count,
                removed: operations.filter { $0.kind == .removeTree }.count,
                moved: operations.filter { $0.kind == .move }.count,
                modified: operations.filter { $0.kind == .update }.count,
                total: session.contexts[target]?.nodes.count ?? 0,
                signature: plan.routes.map(\.impact.signature).joined(separator: ","),
                destructiveSignature: plan.routes.map(\.impact.destructiveSignature).joined(separator: ","))
            var route = BookmarkReviewRoute(
                id: Self.sessionRouteId(target), source: "", target: target.displayName, impact: impact,
                preview: BookmarkChangePreview(before: changes.filter { $0.kind != .added }.map(reviewNode),
                                               after: changes.filter { $0.kind != .removed }.map(reviewNode)))
            route.targetBrowser = target
            routes.append(route)
        }
        let conflicts = session.conflicts.filter { !session.ignored.contains(BookmarkIgnore.conflictKey($0.id)) }.map { conflict in
            BookmarkConflict(
                id: conflict.id, source: conflict.versions[0].bookmark, target: conflict.versions[1].bookmark,
                reason: conflict.reason,
                versions: conflict.versions.map { side in
                    BookmarkConflict.Version(key: side.contentKey, title: side.bookmark.title,
                                             url: side.bookmark.url.flatMap { $0 }, browsers: side.sortedBrowsers)
                })
        }
        if !conflicts.isEmpty {
            var group = BookmarkReviewRoute(
                id: Self.bookmarkSessionConflictRouteId, source: "", target: "",
                impact: .init(added: 0, removed: 0, moved: 0, modified: 0, total: 0, signature: "conflicts", destructiveSignature: ""),
                preview: .init(before: [], after: []), conflicts: conflicts)
            group.isConflictGroup = true
            routes.insert(group, at: 0)
        }
        return routes
    }

    /// Ignores one review row: that exact change into that target is not
    /// planned again until its content differs.
    func ignoreBookmarkReviewRow(routeId: String, rowId: String) {
        guard let session = bookmarkSyncSession,
              let target = session.plans.keys.first(where: { Self.sessionRouteId($0) == routeId }),
              let plan = session.plans[target] else { return }
        var keys = Set<String>()
        for route in plan.routes {
            if let change = BookmarkIgnore.lastChanges(route)[rowId] {
                keys.insert(BookmarkIgnore.changeKey(target: target, change: change))
            }
        }
        guard !keys.isEmpty else { return }
        ignoredBookmarkChanges.formUnion(keys)
        log("Ignored a bookmark change into \(target.displayName); it will not be offered again unless it changes.")
    }

    func ignoreBookmarkConflict(id: String) {
        guard bookmarkSyncSession?.conflicts.contains(where: { $0.id == id }) == true else { return }
        ignoredBookmarkChanges.insert(BookmarkIgnore.conflictKey(id))
        log("Ignored a bookmark conflict; it will not be offered again unless one of its versions changes.")
    }

    func clearIgnoredBookmarkChanges() {
        guard !ignoredBookmarkChanges.isEmpty else { return }
        ignoredBookmarkChanges.removeAll()
        log("Cleared all ignored bookmark changes; the next sync offers them again.")
    }

    func presentBookmarkSyncSessionReview(activate: Bool = true) {
        guard let session = bookmarkSyncSession, session.phase == .reviewing else { return }
        let routes = bookmarkSyncSessionRoutes
        guard routes.contains(where: { !$0.conflicts.isEmpty || BookmarkChangeReviewView.visibleRowCount(for: $0.preview) > 0 }) else {
            discardBookmarkSyncSession(reason: "the plan has no reviewable rows")
            return
        }
        BookmarkChangeReviewWindowController.shared.present(
            clientId: Self.bookmarkSessionReviewKey,
            reviewRoutes: routes,
            activate: activate,
            onApplySelected: { [weak self] selection, _, versionChoices in
                self?.applyBookmarkSyncSession(selection: selection, choices: versionChoices)
            },
            onCancel: { [weak self] in self?.cancelBookmarkSyncSession() },
            onIgnoreRow: { [weak self] routeId, rowId in self?.ignoreBookmarkReviewRow(routeId: routeId, rowId: rowId) },
            onIgnoreConflict: { [weak self] id in self?.ignoreBookmarkConflict(id: id) }
        )
    }

    func cancelBookmarkSyncSession() {
        guard bookmarkSyncSession != nil else { return }
        discardBookmarkSyncSession(reason: "the user cancelled this sync")
        cancelActiveManualSyncIfNeededForSession()
    }

    func discardBookmarkSyncSession(reason: String) {
        guard bookmarkSyncSession != nil else { return }
        bookmarkSyncSession = nil
        AppState.shared.notificationService.removeBookmarkReviewNotification(clientId: Self.bookmarkSessionReviewKey)
        BookmarkChangeReviewWindowController.shared.dismiss(ifPresenting: Self.bookmarkSessionReviewKey)
        publishPendingReviews()
        log("Discarded the pending bookmark sync because \(reason). Nothing was remembered; the next sync recomputes every remaining difference.")
    }

    /// `selection` nil applies every operation (no review was needed).
    private func applyBookmarkSyncSession(selection: [String: Set<String>]?, choices: [String: String]) {
        guard var session = bookmarkSyncSession, session.phase == .reviewing || session.phase == .applying else { return }
        guard session.settingsFingerprint == bookmarkSettingsFingerprint else {
            discardBookmarkSyncSession(reason: "bookmark sync settings changed before it was applied")
            return
        }
        // Conflicts ignored before or during this review need no choice.
        let ignoredConflicts = Set(session.conflicts.map(\.id).filter {
            ignoredBookmarkChanges.contains(BookmarkIgnore.conflictKey($0))
        })
        guard session.conflicts.allSatisfy({ choices[$0.id] != nil || ignoredConflicts.contains($0.id) }) else {
            log("Bookmark sync was not applied: a conflict had no choice.")
            return
        }
        session.phase = .applying
        session.resolutionsApplied = !session.conflicts.isEmpty
        AppState.shared.notificationService.removeBookmarkReviewNotification(clientId: Self.bookmarkSessionReviewKey)

        for target in session.contexts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let context = session.contexts[target], let display = session.plans[target] else { continue }
            let rawPlan = BookmarkAggregatePlanner.plan(target: target, context: context,
                                                        contributions: sessionContributions(session, target: target),
                                                        conflicts: session.conflicts,
                                                        resolutions: session.conflicts.isEmpty ? nil : choices,
                                                        ignoredConflicts: ignoredConflicts)
            let plan = BookmarkIgnore.filtered(rawPlan, ignored: session.ignored)
            // The approval covers exactly the reviewed plan; recomputation
            // must reproduce it before anything is dispatched.
            guard plan.routes.map(\.operations) == display.routes.map(\.operations) else {
                log("Bookmark plan for \(target.displayName) no longer matches what was reviewed; nothing was written there.")
                continue
            }
            if let error = plan.resolution?.validationError {
                log("Conflict choices could not be applied to \(target.displayName): \(error). Nothing was written there.")
                continue
            }
            session.appliedPlans[target] = plan
            session.appliedRawPlans[target] = rawPlan
            var chosen: [BookmarkMutationOperation] = []
            let selected = selection.map { $0[Self.sessionRouteId(target)] ?? [] }
            for route in plan.routes {
                chosen += route.operations.filter { selected?.contains($0.id) ?? true }
            }
            chosen += plan.resolution?.operations ?? []
            // Sibling positions are not synchronized: an index computed in
            // the source would shift other planned inserts into the same
            // folder and make an otherwise correct write fail verification.
            let operations = coalescedBookmarkOperations(BookmarkAggregatePlanner.pruneDependencies(chosen)).map { op -> BookmarkMutationOperation in
                var op = op
                op.index = nil
                return op
            }
            if operations.count < chosen.count {
                log("Left out \(chosen.count - operations.count) bookmark operation(s) for \(target.displayName) that depended on unselected rows.")
            }
            guard !operations.isEmpty else { continue }
            session.dispatched[target] = operations
            if target == .safari {
                prepareSafariForIncomingBookmarkMutation()
                lastNetworkSyncTime = Date()
                recordInternalWrite()
                let result = safariBookmarks.applyNativePlan(operations, inputToken: context.inputToken, scopeRootId: context.scopeRootId)
                if result.applied {
                    session.verified.insert(.safari)
                    log("Wrote and verified \(result.writes) planned bookmark operation(s) in Safari.")
                } else {
                    log("Safari bookmark plan was not written: \(result.error ?? "unknown error"). It will be offered again by the next sync.")
                }
                continue
            }
            guard let clientId = session.clientIds[target],
                  let client = daemon?.connectedClients.first(where: { $0.id == clientId }) else {
                log("\(target.displayName) disconnected before its bookmark plan could be sent. Nothing was written there.")
                continue
            }
            let messageId = UUID().uuidString
            let message = WSMessage(
                type: .sync, site: "*", category: "bookmark_apply_plan",
                payload: .raw([
                    "inputToken": AnyCodable(context.inputToken),
                    "operations": AnyCodable(operations.map { op in
                        ["type": op.kind.rawValue, "id": op.id, "sourceId": op.sourceId as Any, "parentId": op.parentId as Any,
                         "index": op.index as Any, "title": op.title as Any, "url": op.url as Any]
                    })
                ]),
                messageId: messageId, timestamp: Date().timeIntervalSince1970)
            session.outstandingWrites[messageId] = target
            daemon?.sendWSMessage(message, to: client)
            log("Dispatched \(operations.count) planned bookmark operation(s) to [\(clientId)].")
        }
        bookmarkSyncSession = session
        publishPendingReviews()
        if session.outstandingWrites.isEmpty {
            completeBookmarkSessionWrites()
        } else {
            let id = session.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await MainActor.run {
                    guard let self, var session = self.bookmarkSyncSession, session.id == id, !session.outstandingWrites.isEmpty else { return }
                    let missing = Set(session.outstandingWrites.values).map(\.displayName).sorted().joined(separator: ", ")
                    session.outstandingWrites.removeAll()
                    self.bookmarkSyncSession = session
                    self.log("No verified bookmark write result arrived from \(missing); those changes are treated as not applied.")
                    self.completeBookmarkSessionWrites()
                }
            }
        }
    }

    /// When one node receives the same kind of change from two sources, only
    /// the last one describes the final state that can be verified.
    private func coalescedBookmarkOperations(_ operations: [BookmarkMutationOperation]) -> [BookmarkMutationOperation] {
        var seen = Set<String>()
        return operations.reversed().filter { op in
            op.kind == .create || seen.insert("\(op.kind.rawValue)|\(op.id)").inserted
        }.reversed()
    }

    /// Returns true when the result belonged to the current session.
    func acceptSessionBookmarkWriteResult(_ raw: [String: AnyCodable], messageId: String, clientId: String) -> Bool {
        guard var session = bookmarkSyncSession, let target = session.outstandingWrites.removeValue(forKey: messageId) else { return false }
        let operations = session.dispatched[target] ?? []
        if (raw["applied"]?.value as? Bool) == true, (raw["verified"]?.value as? Bool) == true,
           verifyNativeOperationResults(raw["operationResults"]?.value, operations: operations) {
            session.verified.insert(target)
            log("[\(clientId)] wrote and verified \(operations.count) planned bookmark operation(s).")
        } else {
            log("[\(clientId)] did not verify its bookmark write (\((raw["error"]?.value as? String) ?? "results differ from the plan")). It will be offered again by the next sync.")
        }
        bookmarkSyncSession = session
        if session.outstandingWrites.isEmpty { completeBookmarkSessionWrites() }
        return true
    }

    /// All writes are answered: refresh written browsers, then move each
    /// pair's baseline past exactly the changes that are now in the target.
    private func completeBookmarkSessionWrites() {
        guard var session = bookmarkSyncSession else { return }
        session.phase = .finalizing
        for target in session.verified {
            if target == .safari {
                refreshSafariSnapshot()
            } else {
                session.awaitingFreshSnapshots.insert(target)
                requestFreshBookmarkSnapshot(for: session.clientIds[target] ?? target.rawValue)
            }
        }
        bookmarkSyncSession = session
        notifyAutomaticBookmarkSessionResult(session)
        for source in session.observed.keys where !session.awaitingFreshSnapshots.contains(source) {
            finalizeBookmarkSessionSource(source)
        }
        if !session.awaitingFreshSnapshots.isEmpty {
            let id = session.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run {
                    guard let self, var session = self.bookmarkSyncSession, session.id == id else { return }
                    for browser in session.awaitingFreshSnapshots {
                        // Without its post-write tree, advancing would turn
                        // our own writes into "local" changes later.
                        session.finalizedSources.insert(browser)
                        self.log("\(browser.displayName) did not report its tree after the write; its pending changes are kept for the next sync.")
                    }
                    session.awaitingFreshSnapshots.removeAll()
                    self.bookmarkSyncSession = session
                    self.endBookmarkSyncSessionIfDone()
                }
            }
        }
        endBookmarkSyncSessionIfDone()
    }

    /// A browser reported a new snapshot. Returns true when it was the
    /// post-write tree the current session was waiting for.
    func acceptSessionFreshSnapshot(from browser: Browser) -> Bool {
        guard var session = bookmarkSyncSession, session.awaitingFreshSnapshots.contains(browser) else {
            if bookmarkSyncSession != nil { bookmarkSessionNeedsRerun = true }
            return false
        }
        session.awaitingFreshSnapshots.remove(browser)
        bookmarkSyncSession = session
        finalizeBookmarkSessionSource(browser)
        endBookmarkSyncSessionIfDone()
        return true
    }

    private func finalizeBookmarkSessionSource(_ source: Browser) {
        guard var session = bookmarkSyncSession, !session.finalizedSources.contains(source) else { return }
        session.finalizedSources.insert(source)
        bookmarkSyncSession = session
        // Written browsers use their post-write tree, so our own writes are
        // never mistaken for local edits; others use the observed tree.
        let wasWritten = session.verified.contains(source)
        let base = wasWritten
            ? (backupService?.getRecentSnapshots(sourceBrowser: source.rawValue, limit: 1).last?.bookmarks ?? session.observed[source] ?? [])
            : (session.observed[source] ?? [])
        // The post-write tree absorbs only what our verified operations
        // explain; any other difference is a user edit made around the write
        // and stays detectable.
        let concurrentEdits = wasWritten
            ? BookmarkBaseline.unexplainedChanges(observed: session.observed[source] ?? [], fresh: base,
                                                  operations: session.dispatched[source] ?? [],
                                                  nativeNodes: session.contexts[source]?.nodes ?? [])
            : []
        if !concurrentEdits.isEmpty {
            log("Kept \(concurrentEdits.count) edit(s) made in \(source.displayName) around the sync write as pending local changes.")
        }
        for target in settings.bookmarkParticipatingBrowsers where target != source {
            let key = BookmarkSyncSession.pairKey(source, target)
            guard session.deltas[key] != nil || wasWritten || !concurrentEdits.isEmpty else { continue }
            guard session.contexts[target] != nil else { continue } // target unavailable: keep pending
            let unhandled = unhandledChanges(session, source: source, target: target)
            backupService?.saveSyncBaseline(bookmarks: BookmarkBaseline.advanced(observed: base, reverting: concurrentEdits + unhandled),
                                            source: source, target: target)
            if !unhandled.isEmpty {
                log("Kept \(unhandled.count) change(s) from \(source.displayName) pending for \(target.displayName); the next sync offers them again.")
            }
        }
    }

    private func unhandledChanges(_ session: BookmarkSyncSession, source: Browser, target: Browser) -> [BookmarkSnapshotChange] {
        guard let delta = session.deltas[BookmarkSyncSession.pairKey(source, target)] else { return [] }
        // The unfiltered plan: an ignored change has operations that were
        // never dispatched, so it stays pending (and stays ignored).
        let nothingToApply = session.plans[target]?.operations.isEmpty == true
            && session.conflicts.allSatisfy { session.ignored.contains(BookmarkIgnore.conflictKey($0.id)) }
        guard let plan = session.appliedRawPlans[target] ?? (nothingToApply ? session.rawPlans[target] : nil),
              let route = plan.routes.first(where: { $0.source == source }), route.validationError == nil else {
            return delta.changes
        }
        let dispatched = Set((session.dispatched[target] ?? []).map { "\($0.kind.rawValue)|\($0.id)" })
        let verified = session.verified.contains(target)
        let conflictKeys = Set(session.conflicts.flatMap(\.contentKeys))
        let resolutionOK = session.resolutionsApplied && plan.resolution?.validationError == nil
            && ((plan.resolution?.operations.isEmpty ?? true) || verified)
        return delta.changes.filter { change in
            let nodeId = change.nodeId
            let operations = route.operations.filter { $0.sourceId == nodeId }
            if operations.isEmpty {
                if let node = change.after, !node.isFolder, conflictKeys.contains(BookmarkSyncConflict.contentKey(node)) {
                    return !resolutionOK
                }
                return false
            }
            return !(verified && operations.allSatisfy { dispatched.contains("\($0.kind.rawValue)|\($0.id)") })
        }
    }

    private func endBookmarkSyncSessionIfDone() {
        guard let session = bookmarkSyncSession, session.phase == .finalizing,
              session.awaitingFreshSnapshots.isEmpty, session.outstandingWrites.isEmpty else { return }
        for source in session.observed.keys where !session.finalizedSources.contains(source) {
            finalizeBookmarkSessionSource(source)
        }
        bookmarkSyncSession = nil
        publishPendingReviews()
        log("Bookmark sync finished.")
        if bookmarkSessionNeedsRerun {
            bookmarkSessionNeedsRerun = false
            scheduleBookmarkSyncSession()
        }
    }

    private func notifyAutomaticBookmarkSessionResult(_ session: BookmarkSyncSession) {
        guard !session.manual, AppState.shared.settingsService.general.notifySyncComplete else { return }
        var stats = SyncStats()
        for target in session.verified {
            for op in session.dispatched[target] ?? [] {
                let isFolder = op.kind == .create ? op.url == nil : false
                switch op.kind {
                case .create: if isFolder { stats.bookmarkFoldersAdded += 1 } else { stats.bookmarksAdded += 1 }
                case .removeTree: stats.bookmarksDeleted += 1
                case .update, .move: stats.bookmarksModified += 1
                }
            }
        }
        stats.bookmarkSourceBrowserIds = Set(session.deltas.keys.compactMap { $0.components(separatedBy: ">").first }
            .compactMap(Browser.init(rawValue:)).map(\.id))
        guard !stats.isEmpty else { return }
        AppState.shared.notificationService.notifyAutoSyncComplete(stats: stats, categories: [.bookmarks])
    }

    /// The persisted baseline for one pair. Existing installs start from the
    /// previous observation (what the old snapshot-pair logic compared with).
    private func syncBaseline(source: Browser, target: Browser, current: [Bookmark]) -> [Bookmark] {
        if let baseline = backupService?.getSyncBaseline(source: source, target: target) { return baseline }
        let recent = backupService?.getRecentSnapshots(sourceBrowser: source.rawValue, limit: 2) ?? []
        let initial = recent.count == 2 ? recent[0].bookmarks : current
        backupService?.saveSyncBaseline(bookmarks: initial, source: source, target: target)
        log("Established the bookmark sync baseline \(source.displayName) → \(target.displayName).")
        return initial
    }

    private func reconcileLiveTrees(_ session: BookmarkSyncSession) -> BookmarkReconciliation {
        var history: [Browser: [BookmarkSnapshotRecord]] = [:]
        for browser in session.contexts.keys {
            history[browser] = backupService?.getRecentSnapshots(sourceBrowser: browser.rawValue, limit: 256) ?? []
        }
        var evidence: [BookmarkDeletionEvidence] = []
        func collect(_ item: DeletedBookmark) {
            if !item.isFolder, let link = BookmarkSyncConflict.canonicalURL(item.url) {
                for browser in item.browsers { evidence.append(.init(url: link, browser: browser, deletedAt: item.deletedAt)) }
            }
            item.children?.forEach(collect)
        }
        backupService?.deletedBookmarksForSyncEvidence().forEach(collect)
        return BookmarkReconciler.reconcile(observed: session.observed, live: session.contexts, history: history,
                                            deletions: evidence, pendingURLs: pendingBookmarkURLs(session))
    }

    /// URLs touched by any pending source → target change.
    private func pendingBookmarkURLs(_ session: BookmarkSyncSession) -> Set<String> {
        var pending = Set<String>()
        for delta in session.deltas.values {
            for change in delta.changes {
                for node in [change.before, change.after].compactMap({ $0 }) where !node.isFolder {
                    if let link = BookmarkSyncConflict.canonicalURL(node.url) { pending.insert(link) }
                }
            }
        }
        return pending
    }

    /// Local deletions are listed in Recently Deleted once detected.
    private func recordDetectedBookmarkDeletions(_ session: BookmarkSyncSession) {
        var bySource: [Browser: [Bookmark]] = [:]
        for (key, removed) in session.reconciliation.removals {
            guard let origin = key.components(separatedBy: ">").first.flatMap(Browser.init(rawValue:)) else { continue }
            for node in removed where !(bySource[origin] ?? []).contains(where: { $0.id == node.id }) {
                bySource[origin, default: []].append(node)
            }
        }
        for (key, delta) in session.deltas {
            guard let source = key.components(separatedBy: ">").first.flatMap(Browser.init(rawValue:)) else { continue }
            let baseline = session.baselines[key] ?? []
            let children = Dictionary(grouping: baseline, by: { $0.parentId ?? "" })
            for removed in delta.removed {
                // A removed folder is one change; its subtree comes from the baseline.
                var queue = [removed]
                while let node = queue.popLast() {
                    if !(bySource[source] ?? []).contains(where: { $0.id == node.id }) { bySource[source, default: []].append(node) }
                    queue.append(contentsOf: children[node.id] ?? [])
                }
            }
        }
        for (source, removed) in bySource where !removed.isEmpty {
            backupService?.addDeletedBookmarks(buildDeletedBookmarkForest(from: removed, sourceBrowser: source.rawValue))
        }
    }

    private func cancelActiveManualSyncIfNeededForSession() {
        guard activeManualSyncID != nil else { return }
        activeManualSyncID = nil
        lastManualSyncWasCancelled = true
        isSyncing = false
    }
}

// MARK: - Backup restore

extension SyncService {
    /// The browser a backup belongs to ("safari", "chrome-<instance>", ...).
    static func restoreBrowser(forBackupSource source: String) -> Browser? {
        Browser(rawValue: (source.components(separatedBy: "-").first ?? source).lowercased())
    }

    /// Restores a backup into the browser it was taken from, inside that
    /// browser's selected folder, through the scoped native planner and a
    /// verified write. The confirmation that called this is the explicit
    /// approval (so the one-way-source exception applies to this browser
    /// only); other browsers follow through a normal sync session.
    func restoreBackup(archive: [Bookmark], archiveFolder: String?, source: String, replacing: Bool,
                       completion: @escaping (BookmarkRestoreOutcome?) -> Void) {
        func fail(_ reason: String) {
            log("Backup restore was not performed: \(reason). Nothing was reported as restored.")
            completion(nil)
        }
        guard let browser = Self.restoreBrowser(forBackupSource: source) else { return fail("the backup's browser is unknown") }
        guard BookmarkWritePolicy.allowsWrite(to: browser, settings: settings, explicitRestore: true) else {
            return fail("bookmark sync is off or \(browser.displayName) is not participating")
        }
        if let phase = bookmarkSyncSession?.phase, phase == .applying || phase == .finalizing {
            return fail("a bookmark sync is writing right now; try again when it finishes")
        }
        let scope = BookmarkRestorePlanner.scope(archive: archive, archiveFolder: archiveFolder,
                                                 targetFolder: settings.bookmarkFolder(for: browser))
        guard scope.isRestorable else { return fail("the backup does not contain \(browser.displayName)'s sync folder") }
        guard !replacing || scope.allowsReplace else {
            return fail("Replace Restore needs the backup and the sync folder to cover the same folder")
        }
        // The bound folder in the live browser: its sync folder, or the
        // backup's own folder when the browser syncs its whole library.
        let targetFolder = scope.effectiveFolder
        let desired = BookmarkRestorePlanner.portableTree(archive: archive, scope: scope)
        guard !desired.isEmpty else { return fail("the backup contains no restorable bookmarks") }

        if browser == .safari {
            guard SandboxAccessManager.shared.hasSafariAccess else { return fail("Safari folder access has not been granted") }
            let read = safariBookmarks.nativePlanContext(folderPath: targetFolder)
            guard let context = read.context else {
                return fail(read.error ?? "Safari bookmarks are unavailable")
            }
            let plan = BookmarkRestorePlanner.plan(desired: desired, context: context, replacing: replacing)
            if let error = plan.validationError { return fail(error) }
            let operations = restoreOperations(plan.operations)
            guard !operations.isEmpty else { return finishRestore(browser: browser, operations: [], completion: completion) }
            backupSafariBeforeRestore()
            lastNetworkSyncTime = Date()
            recordInternalWrite()
            let result = safariBookmarks.applyNativePlan(operations, inputToken: context.inputToken,
                                                         scopeRootId: context.scopeRootId, explicitRestore: true)
            guard result.applied else { return fail(result.error ?? "the Safari write could not be verified") }
            refreshSafariSnapshot()
            return finishRestore(browser: browser, operations: operations, completion: completion)
        }

        guard let client = daemon?.connectedClients.first(where: { $0.browser == browser }),
              mayWriteBookmarks(to: client, explicitRestore: true) else {
            return fail("\(browser.displayName) is not connected with a current BrowSync extension")
        }
        let requestId = UUID().uuidString
        pendingRestoreContexts[requestId] = PendingBookmarkRestore(browser: browser, clientId: client.id, desired: desired,
                                                                   replacing: replacing, targetFolder: targetFolder,
                                                                   archiveFolder: archiveFolder, completion: completion)
        let request = WSMessage(type: .pull, site: requestId, category: "bookmark_plan_context",
                                payload: .raw(["requestId": AnyCodable(requestId),
                                               "targetFolder": AnyCodable(targetFolder ?? NSNull())]),
                                messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
        daemon?.sendBookmarkControlMessage(request, to: client)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await MainActor.run {
                guard let self, let pending = self.pendingRestoreContexts.removeValue(forKey: requestId) else { return }
                self.log("Backup restore into [\(pending.clientId)] timed out waiting for its current tree. Nothing was written.")
                pending.completion(nil)
            }
        }
    }

    /// Captures Safari's synced scope immediately before a restore writes it,
    /// even if a backup was taken moments ago (identical content is still
    /// deduplicated), then suppresses follow-up backups of our own write.
    private func backupSafariBeforeRestore() {
        let raw = safariBookmarks.readBookmarks().map {
            Bookmark(id: $0.id, title: $0.title, url: $0.url, parentId: $0.parentId, isFolder: $0.isFolder,
                     sortIndex: $0.sortIndex, inBookmarksBar: $0.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
        }
        if let backup = backupBookmarksForSource(raw, browser: .safari) {
            _ = backupService?.savePreSyncBackup(bookmarks: backup, sourceBrowser: "safari",
                                                 folderPath: settings.bookmarkFolder(for: .safari), bypassBurstSuppression: true)
        }
        suppressSafariPreSyncBackupUntil = Date().addingTimeInterval(15)
    }

    /// Sibling positions are not replayed: later inserts would shift earlier
    /// ones and fail verification. Creation order preserves backup order.
    private func restoreOperations(_ operations: [BookmarkMutationOperation]) -> [BookmarkMutationOperation] {
        operations.map { op in
            var op = op
            op.index = nil
            return op
        }
    }

    func acceptRestoreContext(_ raw: [String: AnyCodable], requestId: String, clientId: String) -> Bool {
        guard var pending = pendingRestoreContexts[requestId], pending.clientId == clientId else { return false }
        pendingRestoreContexts.removeValue(forKey: requestId)
        func fail(_ reason: String) {
            log("Backup restore into [\(clientId)] was not performed: \(reason). Nothing was reported as restored.")
            pending.completion(nil)
        }
        guard let context = nativeTreeContext(from: raw, browser: pending.browser) else {
            fail((raw["error"]?.value as? String).map { "\($0) (\(pending.targetFolder ?? "whole library"))" }
                 ?? "it returned no valid current tree")
            return true
        }
        guard BookmarkWritePolicy.allowsWrite(to: pending.browser, settings: settings, explicitRestore: true) else {
            fail("bookmark sync settings changed")
            return true
        }
        // The confirmation named a folder; if the sync folder changed since,
        // that confirmation no longer describes this write.
        let configured = settings.bookmarkFolder(for: pending.browser)
        let currentTarget = (configured?.isEmpty ?? true) ? pending.archiveFolder : configured
        guard BookmarkFolderPath.canonicalized(currentTarget) == BookmarkFolderPath.canonicalized(pending.targetFolder) else {
            fail("the browser's sync folder changed after the restore was confirmed")
            return true
        }
        guard BookmarkRestorePlanner.contextMatchesRequestedScope(context, requestedFolder: pending.targetFolder) else {
            fail("the browser did not report the requested folder as its scope")
            return true
        }
        // The target scope is saved before anything is replayed into it,
        // even if another backup of it was taken seconds ago.
        _ = backupService?.savePreSyncBackup(bookmarks: BookmarkRestorePlanner.archive(of: context), sourceBrowser: clientId,
                                             folderPath: pending.targetFolder, bypassBurstSuppression: true)
        let plan = BookmarkRestorePlanner.plan(desired: pending.desired, context: context, replacing: pending.replacing)
        if let error = plan.validationError {
            fail(error)
            return true
        }
        let operations = restoreOperations(plan.operations)
        guard !operations.isEmpty else {
            finishRestore(browser: pending.browser, operations: [], completion: pending.completion)
            return true
        }
        guard let client = daemon?.connectedClients.first(where: { $0.id == clientId }) else {
            fail("the browser disconnected")
            return true
        }
        let messageId = UUID().uuidString
        var message = WSMessage(
            type: .sync, site: "*", category: "bookmark_apply_plan",
            payload: .raw([
                "inputToken": AnyCodable(context.inputToken),
                "operations": AnyCodable(operations.map { op in
                    ["type": op.kind.rawValue, "id": op.id, "sourceId": op.sourceId as Any, "parentId": op.parentId as Any,
                     "index": op.index as Any, "title": op.title as Any, "url": op.url as Any]
                })
            ]),
            messageId: messageId, timestamp: Date().timeIntervalSince1970)
        message.isExplicitBookmarkRestore = true
        pending.operations = operations
        pendingRestoreWrites[messageId] = pending
        daemon?.sendWSMessage(message, to: client)
        log("Dispatched a confirmed backup restore (\(operations.count) operation(s)) to [\(clientId)].")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await MainActor.run {
                guard let self, let pending = self.pendingRestoreWrites.removeValue(forKey: messageId) else { return }
                self.log("No verified result arrived for the backup restore into [\(pending.clientId)]; it is not reported as restored.")
                self.lateRestoreWrites[messageId] = pending.clientId
                pending.completion(nil)
            }
        }
        return true
    }

    func acceptRestoreWriteResult(_ raw: [String: AnyCodable], messageId: String, clientId: String) -> Bool {
        if lateRestoreWrites.removeValue(forKey: messageId) != nil {
            log("A late result arrived for a timed-out backup restore into [\(clientId)]; re-reading its bookmarks.")
            requestFreshBookmarkSnapshot(for: clientId)
            scheduleBookmarkSyncSession()
            return true
        }
        guard let pending = pendingRestoreWrites.removeValue(forKey: messageId) else { return false }
        guard (raw["applied"]?.value as? Bool) == true, (raw["verified"]?.value as? Bool) == true,
              verifyNativeOperationResults(raw["operationResults"]?.value, operations: pending.operations) else {
            log("Backup restore into [\(clientId)] was not verified (\((raw["error"]?.value as? String) ?? "results differ from the plan")); some operations may have been written. It is not reported as restored; re-reading the browser.")
            // An extension applies operations one by one: a failed result can
            // still mean a partial write, which the next sync must see.
            requestFreshBookmarkSnapshot(for: clientId)
            scheduleBookmarkSyncSession()
            pending.completion(nil)
            return true
        }
        requestFreshBookmarkSnapshot(for: clientId)
        finishRestore(browser: pending.browser, operations: pending.operations, completion: pending.completion)
        return true
    }

    private func finishRestore(browser: Browser, operations: [BookmarkMutationOperation],
                               completion: (BookmarkRestoreOutcome?) -> Void) {
        let outcome = BookmarkRestoreOutcome(
            browser: browser,
            added: operations.filter { $0.kind == .create }.count,
            removed: operations.filter { $0.kind == .removeTree }.count,
            updated: operations.filter { $0.kind == .update || $0.kind == .move }.count)
        log("Restored a backup into \(browser.displayName): \(outcome.added) added, \(outcome.removed) removed, \(outcome.updated) updated. Other browsers follow through normal sync.")
        completion(outcome)
        // A review computed before the restore no longer describes the trees.
        if !operations.isEmpty, let phase = bookmarkSyncSession?.phase, phase == .collecting || phase == .reviewing {
            discardBookmarkSyncSession(reason: "a backup was restored into \(browser.displayName)")
        }
        // The restore is now a local change of that browser; a session
        // propagates it under the user's direction, folders and Safe Mode.
        scheduleBookmarkSyncSession()
    }
}

// MARK: - Manual backup

extension SyncService {
    /// Backs up every participating browser's synced folder now (with its
    /// ancestor chain). Safari is read directly; other browsers are asked for
    /// a fresh snapshot. A browser that is not connected, or whose sync folder
    /// is missing, is reported as not backed up — an old snapshot is never
    /// passed off as a current backup.
    func backUpBookmarksNow(completion: @escaping (_ succeeded: [Browser], _ failed: [Browser]) -> Void) {
        // A second request while one runs (e.g. the settings view was
        // recreated) joins it, so every caller hears the outcome.
        if manualBackupRun != nil {
            manualBackupRun?.completions.append(completion)
            return
        }
        var run = ManualBackupRun(completions: [completion])
        let browsers = settings.bookmarkParticipatingBrowsers.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        for browser in browsers {
            if browser == .safari {
                let raw = SandboxAccessManager.shared.hasSafariAccess ? safariBookmarks.readBookmarks().map {
                    Bookmark(id: $0.id, title: $0.title, url: $0.url, parentId: $0.parentId, isFolder: $0.isFolder,
                             sortIndex: $0.sortIndex, inBookmarksBar: $0.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                } : []
                let saved = !raw.isEmpty && (backupBookmarksForSource(raw, browser: .safari).map {
                    backupService?.saveManualBackup(bookmarks: $0, sourceBrowser: "safari",
                                                    folderPath: settings.bookmarkFolder(for: .safari)) ?? false
                } ?? false)
                if saved { run.succeeded.append(.safari) } else { run.failed.append(.safari) }
            } else if let client = daemon?.connectedClients.first(where: { $0.browser == browser }) {
                run.waiting.insert(browser)
                requestFreshBookmarkSnapshot(for: client.id)
            } else {
                run.failed.append(browser)
            }
        }
        manualBackupRun = run
        log("Manual bookmark backup started for \(browsers.map(\.displayName).joined(separator: ", ")).")
        guard !run.waiting.isEmpty else { return finishManualBackup() }
        let id = run.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await MainActor.run {
                guard let self, var run = self.manualBackupRun, run.id == id, !run.waiting.isEmpty else { return }
                run.failed.append(contentsOf: run.waiting)
                run.waiting.removeAll()
                self.manualBackupRun = run
                self.finishManualBackup()
            }
        }
    }

    func resolveManualBackup(_ browser: Browser, saved: Bool) {
        guard var run = manualBackupRun, run.waiting.remove(browser) != nil else { return }
        if saved { run.succeeded.append(browser) } else { run.failed.append(browser) }
        manualBackupRun = run
        if run.waiting.isEmpty { finishManualBackup() }
    }

    private func finishManualBackup() {
        guard let run = manualBackupRun else { return }
        manualBackupRun = nil
        let order: (Browser, Browser) -> Bool = { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let succeeded = run.succeeded.sorted(by: order), failed = run.failed.sorted(by: order)
        log("Manual bookmark backup finished: saved \(succeeded.map(\.displayName)), not saved \(failed.map(\.displayName)).")
        run.completions.forEach { $0(succeeded, failed) }
    }
}

// MARK: - Sync Log Entry

struct SyncLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}
