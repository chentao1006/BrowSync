// SyncService.swift
// BrowSync — Orchestrates sync operations between browsers via the Daemon

import Foundation
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
    @Published var syncLog: [SyncLogEntry] = []
    /// Bookmark count per browser ID (e.g. "safari", "chrome"). Updated on sync.
    @Published var bookmarkCounts: [String: Int] = [:]
    
    private var currentManualSyncStats = SyncStats()
    private struct SilentBrowserDataPull {
        let requesterClientId: String
        let site: String?
        let expiresAt: Date
    }
    private var silentBrowserDataPulls: [SilentBrowserDataPull] = []
    private var pendingEmptyBookmarkSnapshots: [String: PendingEmptyBookmarkSnapshot] = [:]
    private var forceAcceptedEmptyBookmarkMessageIds = Set<String>()

    // A single deliberate deletion arrives as one `bookmarks_removed` message, but a
    // misbehaving extension/browser sync can emit dozens within seconds. Each one is
    // applied to Safari and rebroadcast to every other participant, so an unchecked
    // burst can wipe every synced browser in one shot. Buffer per-client and only
    // auto-apply small batches; anything larger waits for explicit user confirmation.
    private static let bookmarkRemovalBurstThreshold = 8
    // Extensions report removals immediately so MV3 worker suspension cannot
    // lose an in-memory timer. The native app owns the quiet window instead:
    // collect a browser's removal burst for 10 seconds, then deduplicate and
    // apply it or require confirmation when it crosses the safety threshold.
    private static let bookmarkRemovalBurstDebounceNanoseconds: UInt64 = 10_000_000_000
    private var pendingBookmarkRemovalBuffers: [String: [Bookmark]] = [:]
    private var bookmarkRemovalBurstTasks: [String: Task<Void, Never>] = [:]
    private var pendingBookmarkRemovalBursts: [String: [Bookmark]] = [:]
    // Deletion events are not the only destructive path: a malformed tree can
    // relocate most of Safari's bookmarks without deleting any. Automatic writes
    // that would remove or move many existing items wait here for the user.
    private struct PendingSafariWrite {
        let sourceName: String
        let held: SafariBookmarkService.HeldWrite
        /// Set when the held write is a batch of removal events (already
        /// limited to the source's sync folder): after Safari is written, the
        /// same removals are recorded and sent to the others.
        var removals: [Bookmark]? = nil
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

    // Writes into other browsers are computed by their extensions as a dry
    // run; a large one is reported here instead of being written. After
    // review the app re-sends the same message with the plan's signature.
    // Keyed "to:<clientId>" (a key without the prefix is a write into Safari).
    private struct PendingBrowserWrite {
        let message: WSMessage
        let impact: SafariBookmarkService.WriteImpact
        let preview: BookmarkChangePreview
        let settingsFingerprint: String
    }
    private var pendingBrowserWrites: [String: PendingBrowserWrite] = [:] {
        didSet { publishPendingReviews() }
    }
    /// The last bookmark sync sent to each browser, to re-send after approval.
    private var lastBookmarkMessageByClient: [String: WSMessage] = [:]
    /// Browsers with a removal batch not yet answered (held or written).
    private var unacknowledgedRemovalBatches = Set<String>()
    private static let removalBatchAnswerTimeout: UInt64 = 120_000_000_000

    /// A removal batch that will not be answered (browser gone, its sync
    /// folder missing, no answer in time): the browser is no longer treated as
    /// under review, and the deletions wait for its next connection instead
    /// of being lost.
    func abandonRemovalBatch(for clientId: String, reason: String) {
        guard unacknowledgedRemovalBatches.remove(clientId) != nil else { return }
        removalBatchTimerTokens.removeValue(forKey: clientId)
        if case .bookmarks(let items)? = lastBookmarkMessageByClient["rm:" + clientId]?.payload {
            keepUndeliveredRemovals(items, for: clientId)
        }
        // Still connected (no answer in time, settings changed): try again now
        // rather than at the next reconnect, which can be hours away — but
        // not endlessly for a browser that never answers; its removals then
        // wait for its next connection.
        if reason == "timeout" {
            removalBatchTimeouts[clientId, default: 0] += 1
        }
        if (reason == "timeout" && removalBatchTimeouts[clientId, default: 0] <= 2) || reason == "bookmark sync settings changed" {
            DispatchQueue.main.async { [weak self] in
                _ = self?.deliverPendingBrowserRemovals(to: clientId)
            }
        }
        log("No answer to the bookmark removal batch for [\(clientId)] (\(reason)); its deletions are kept for the next connection.")
    }

    /// Each send (including an approved re-send) gets its own token, so an
    /// older timer never abandons a newer send of the same batch.
    private var removalBatchTimerTokens: [String: UUID] = [:]
    /// Consecutive unanswered batches per browser; reset by any answer or a reconnect.
    private var removalBatchTimeouts: [String: Int] = [:]
    private func armRemovalBatchTimer(for clientId: String) {
        let token = UUID()
        removalBatchTimerTokens[clientId] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.removalBatchAnswerTimeout)
            guard let self, self.removalBatchTimerTokens[clientId] == token else { return }
            self.abandonRemovalBatch(for: clientId, reason: "timeout")
        }
    }

    /// Deletions made in another browser that could not be delivered to this
    /// one (kept per browser instance, persisted). Unlike Safari's own pending
    /// removals they are not checked against Safari: Safari may not take part,
    /// and a Safari bookmark with the same title says nothing about them.
    private var pendingBrowserRemovals: [String: [Bookmark]] = [:]
    private var pendingBrowserRemovalsURL: URL {
        dataDir.appendingPathComponent("pending-browser-bookmark-removals.json")
    }

    private func loadPendingBrowserRemovals() {
        guard let data = try? Data(contentsOf: pendingBrowserRemovalsURL),
              let saved = try? JSONDecoder().decode([String: [Bookmark]].self, from: data) else { return }
        pendingBrowserRemovals = saved
    }

    private func savePendingBrowserRemovals() {
        guard let data = try? JSONEncoder().encode(pendingBrowserRemovals) else { return }
        do { try data.write(to: pendingBrowserRemovalsURL, options: .atomic) }
        catch { log("Could not save pending bookmark removals: \(error.localizedDescription)") }
    }

    /// Undelivered removals, kept by origin: Safari's own go through Safari's
    /// "restored meanwhile" check on delivery, the others are delivered as is.
    private func keepUndeliveredRemovals(_ items: [Bookmark], for clientId: String) {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        let fromSafari = items.filter { $0.sourceBrowser == .safari }
        let fromBrowsers = items.filter { $0.sourceBrowser != .safari }
        if !fromSafari.isEmpty { queuePendingSafariRemovals(fromSafari, forBrowserId: browserId) }
        // Only browsers that can be delivered to later keep removals.
        guard !fromBrowsers.isEmpty, Browser(rawValue: browserId) != nil else { return }
        var pending = pendingBrowserRemovals[clientId] ?? []
        for item in fromBrowsers where !pending.contains(where: { $0.id == item.id }) {
            pending.append(item)
        }
        pendingBrowserRemovals[clientId] = pending
        savePendingBrowserRemovals()
    }

    /// On (re)connect, in any sync mode: one batch, reviewed by the extension.
    func deliverPendingBrowserRemovals(to clientId: String) -> Bool {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        guard let items = pendingBrowserRemovals[clientId], !items.isEmpty,
              let browser = Browser(rawValue: browserId) else { return false }
        // Delivered only as the current settings would route them. A browser
        // not taking part right now keeps its removals: participation can be
        // limited only until the purchase status has loaded at launch, and
        // dropping them would let its next snapshot bring the bookmarks back.
        guard settings.enabledCategories.contains(.bookmarks),
              settings.bookmarkParticipatingBrowsers.contains(browser) else { return false }
        // In one-way sync only deletions from the source browser reach the
        // others; the reviewed full mirror brings the rest in line.
        let routed: [Bookmark]
        if settings.bookmarkSyncStrategy == .twoWayMerge {
            routed = items
        } else {
            let source = settings.bookmarkSourceBrowser
            routed = browser == source ? [] : items.filter { $0.sourceBrowser == source }
        }
        if routed.count < items.count {
            // Decided first, so unrouted items never wait on anything else.
            log("Dropped \(items.count - routed.count) pending bookmark removals for [\(clientId)] that the current sync direction does not send.")
            if routed.isEmpty {
                pendingBrowserRemovals.removeValue(forKey: clientId)
            } else {
                pendingBrowserRemovals[clientId] = routed
            }
            savePendingBrowserRemovals()
            guard !routed.isEmpty else { return false }
        }
        guard missingBookmarkFolders[browserId] == nil,
              let client = daemon?.connectedClients.first(where: { $0.id == clientId }),
              mayWriteBookmarks(to: client) else { return false }
        pendingBrowserRemovals.removeValue(forKey: clientId)
        savePendingBrowserRemovals()
        sendBookmarkRemovalBatch(routed, browsers: [browser], onlyClientId: clientId)
        log("Delivered \(routed.count) pending bookmark removals to [\(clientId)]")
        return true
    }

    /// Participation can change without a reconnect (purchase status loading
    /// at launch, settings): deliver kept removals to every connected browser
    /// then, and ask for its tree once they are in.
    func deliverAllPendingBrowserRemovals() {
        for client in daemon?.connectedClients ?? [] where deliverPendingBrowserRemovals(to: client.id) {
            let refresh = WSMessage(type: .sync, site: "*", category: "bookmarks", payload: nil,
                                    messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
            daemon?.sendWSMessage(refresh, to: client)
        }
    }

    /// The browser answered a removal batch (late or not): whatever of it was
    /// kept for re-delivery has arrived.
    private func settleKeptRemovals(answeredBy clientId: String) {
        guard case .bookmarks(let answered)? = lastBookmarkMessageByClient["rm:" + clientId]?.payload,
              var kept = pendingBrowserRemovals[clientId] else { return }
        let ids = Set(answered.map(\.id))
        kept.removeAll { ids.contains($0.id) }
        pendingBrowserRemovals[clientId] = kept.isEmpty ? nil : kept
        savePendingBrowserRemovals()
    }

    func resetRemovalBatchTimeouts(for clientId: String) {
        removalBatchTimeouts.removeValue(forKey: clientId)
    }

    private func queuePendingSafariRemovals(_ items: [Bookmark], forBrowserId browserId: String) {
        var pending = pendingSafariRemovals[browserId] ?? []
        for item in items where !pending.contains(where: { $0.id == item.id }) {
            pending.append(item)
        }
        pendingSafariRemovals[browserId] = pending
        savePendingSafariRemovals()
    }

    /// While a browser's incoming change is under review (or a removal batch
    /// to it is unanswered), its snapshots still show what is being reviewed
    /// (e.g. a folder deleted elsewhere). Merging them into Safari or
    /// forwarding them would undo the change before the user decides.
    private func isAwaitingReview(of clientId: String) -> Bool {
        pendingBrowserWrites["to:" + clientId] != nil
            || pendingBrowserWrites["to:rm:" + clientId] != nil
            || unacknowledgedRemovalBatches.contains(clientId)
            // Deletions it has not received yet: its tree still has them.
            || (pendingBrowserRemovals[clientId]?.isEmpty == false
                && Browser(rawValue: clientId.components(separatedBy: "-").first ?? clientId) != nil)
    }

    private func publishPendingReviews() {
        AppState.shared.pendingBookmarkReviewClientIds = (Array(pendingSafariWrites.keys) + Array(pendingBrowserWrites.keys)).sorted()
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
    private func runSafariCleanup(_ held: SafariBookmarkService.HeldWrite?, key: String) {
        guard let held, held.impact.affected > 0 else { return }
        if held.impact.requiresConfirmation {
            holdLargeSafariWrite(PendingSafariWrite(sourceName: "BrowSync cleanup", held: held), clientId: key)
        } else {
            prepareSafariForIncomingBookmarkMutation()
            guard safariBookmarks.commitHeldWrite(held, from: "BrowSync cleanup") != nil else { return }
            log("Cleaned up \(held.impact.affected) bookmarks BrowSync had written into Safari by mistake.")
            refreshSafariSnapshot()
        }
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
    var settings: SyncSettings {
        var current = settingsService?.syncSettings ?? SyncSettings()
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
    // Explicit Safari removals must survive an offline browser and an app restart.
    private var pendingSafariRemovals: [String: [Bookmark]] = [:]
    private var lastNetworkSyncTime: Date = Date.distantPast
    private var suppressSafariPreSyncBackupUntil: Date = .distantPast
    @Published var missingBookmarkFolders: [String: String] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("BrowSync")
        createDataDirectories()
        loadPendingSafariRemovals()
        loadPendingBrowserRemovals()
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
        let tree = bookmarkTreeSnapshot(for: browser)
        guard !tree.isEmpty else { return false }
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
            if let cachedSafari = backupService?.getSnapshot(sourceBrowser: "safari"), !cachedSafari.isEmpty {
                return cachedSafari
            }
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
        let wasMissing = missingBookmarkFolders.removeValue(forKey: browser.rawValue) != nil
        if wasMissing {
            // Removals kept while the folder was missing can go out now.
            for client in daemon?.connectedClients ?? [] where client.browser == browser {
                _ = deliverPendingBrowserRemovals(to: client.id)
            }
        }
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
        return BookmarkTreeMerger.extractExistingSubtreeIncludingRoot(sourceTree: archivalTree, folderPath: folder)
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

    private func bookmarkDeletionIsInsideSelectedFolder(_ bookmark: Bookmark, browser: Browser, clientId: String) -> Bool {
        guard let folder = settings.bookmarkFolder(for: browser), !folder.isEmpty else { return true }
        guard let selectedSnapshot = BookmarkTreeMerger.extractExistingSubtreeAsRoot(sourceTree: snapshotForClient(clientId), folderPath: folder) else {
            markMissingBookmarkFolder(browser, folder: folder)
            return false
        }

        if selectedSnapshot.contains(where: { $0.id == bookmark.id }) { return true }
        if let url = bookmarkURL(bookmark)?.lowercased(),
           selectedSnapshot.contains(where: { bookmarkURL($0)?.lowercased() == url }) {
            return true
        }
        if bookmark.isFolder {
            let title = bookmark.title.lowercased()
            return selectedSnapshot.contains { $0.isFolder && $0.title.lowercased() == title }
        }
        return false
    }

    /// Entry point for every incoming `bookmarks_removed` message. Buffered per
    /// client and coalesced by a quiet-period debounce so a rapid-fire burst of
    /// individual removal events (e.g. a browser's own account sync churning
    /// through reconciliation) is evaluated as one batch instead of each item
    /// being trusted and propagated the instant it arrives.
    private func handleIncomingBookmarkRemoval(_ bm: Bookmark, clientId: String) {
        pendingBookmarkRemovalBuffers[clientId, default: []].append(bm)
        bookmarkRemovalBurstTasks[clientId]?.cancel()
        bookmarkRemovalBurstTasks[clientId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.bookmarkRemovalBurstDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.flushBookmarkRemovalBuffer(for: clientId)
            }
        }
    }

    /// Browser workers report create/update/move activity immediately. Keep
    /// the restartable quiet-period timer in the long-lived native app.
    private func handleIncomingBookmarkChangeSignal(clientId: String) {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        guard let browser = Browser(rawValue: browserId),
              settings.bookmarkParticipatingBrowsers.contains(browser),
              settings.bookmarkSyncStrategy != .oneWay || settings.bookmarkSourceBrowser == browser else { return }
        let isPro = AppState.shared.purchaseService.isProUnlocked
        guard (isPro && settings.bookmarkAutoSync && settings.enabledCategories.contains(.bookmarks)) || isSyncing else { return }

        bookmarkChangeDebounceTasks[clientId]?.cancel()
        bookmarkChangeDebounceTasks[clientId] = Task { [weak self] in
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

    private func flushBookmarkRemovalBuffer(for clientId: String) {
        bookmarkRemovalBurstTasks[clientId] = nil
        guard let items = pendingBookmarkRemovalBuffers.removeValue(forKey: clientId), !items.isEmpty else { return }
        // Limited to the source's sync folder once, as they arrive. A batch
        // still awaiting review absorbs them as is (it was filtered when it
        // arrived; the source's newer snapshots no longer contain its items).
        let earlier = pendingSafariWrites["rm:" + clientId]?.removals ?? []
        let fresh = removalsInsideSyncFolder(items, clientId: clientId).filter { item in !earlier.contains { $0.id == item.id } }
        let eligible = earlier + fresh
        guard !eligible.isEmpty else { return }

        // Weigh removals by what they take with them: removing one folder can
        // remove thousands of bookmarks, so counting events is not enough.
        let sourceSnapshot = snapshotForClient(clientId)
        let removedWeight = removalWeight(of: eligible, in: sourceSnapshot)
        let tooLarge = eligible.count > Self.bookmarkRemovalBurstThreshold
            || removedWeight > max(Self.bookmarkRemovalBurstThreshold, sourceSnapshot.count / 20)
        // Dry run against Safari: the review shows exactly what Safari loses.
        let safariPreview = settings.bookmarkParticipatingBrowsers.contains(.safari) && SandboxAccessManager.shared.hasSafariAccess
            ? safariBookmarks.previewRemovals(eligible.map { ($0.id, $0.title, $0.url ?? nil) })
            : nil
        // Safari's own review covers Safari. Every other browser receives the
        // batch and reviews it in its extension, so nothing is held here when
        // Safari would not change (an empty review would also share one
        // signature across unrelated batches).
        if let held = safariPreview, held.impact.affected > 0, tooLarge || held.impact.requiresConfirmation {
            log("Held \(eligible.count) bookmark deletion events from [\(clientId)] (\(held.impact.removed) Safari items) for review.")
            holdLargeSafariWrite(PendingSafariWrite(sourceName: clientId, held: held, removals: eligible), clientId: "rm:" + clientId)
            return
        }
        applyBookmarkRemovals(eligible, clientId: clientId)
    }

    private func removalsInsideSyncFolder(_ items: [Bookmark], clientId: String) -> [Bookmark] {
        guard let browser = Browser(rawValue: clientId.components(separatedBy: "-").first ?? clientId) else { return items }
        return items.filter { bm in
            guard !bookmarkDeletionIsInsideSelectedFolder(bm, browser: browser, clientId: clientId) else { return true }
            log("Ignored \(bm.isFolder ? "folder" : "bookmark") deletion (id \(bm.id)) from [\(clientId)] outside selected sync folder")
            return false
        }
    }

    /// The removed items plus everything below them in the source's last snapshot.
    private func removalWeight(of items: [Bookmark], in snapshot: [Bookmark]) -> Int {
        let childrenByParent = Dictionary(grouping: snapshot.filter { $0.parentId != nil }, by: { $0.parentId! })
        var seen = Set<String>()
        func count(_ id: String) -> Int {
            guard seen.insert(id).inserted else { return 0 }
            return 1 + (childrenByParent[id] ?? []).reduce(0) { $0 + count($1.id) }
        }
        return items.reduce(0) { $0 + count($1.id) }
    }

    private var bookmarkSettingsFingerprint: String {
        let s = settings
        return [
            String(describing: s.bookmarkSyncStrategy),
            s.bookmarkSourceBrowser.rawValue,
            s.bookmarkParticipatingBrowsers.map(\.rawValue).sorted().joined(separator: ","),
            s.enabledCategories.contains(.bookmarks) ? "on" : "off",
            Browser.allCases.map { "\($0.rawValue)=\(s.bookmarkFolder(for: $0) ?? "")" }.joined(separator: ",")
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
        if lastSettingsFingerprintSeen != bookmarkSettingsFingerprint {
            lastSettingsFingerprintSeen = bookmarkSettingsFingerprint
            for clientId in unacknowledgedRemovalBatches.sorted() {
                abandonRemovalBatch(for: clientId, reason: "bookmark sync settings changed")
            }
        }
        for key in pendingBrowserWrites.keys.sorted() {
            _ = validPendingBrowserWrite(key: key)
        }
        deliverAllPendingBrowserRemovals()
        let pendingBefore = pendingSafariWrites.count
        for clientId in pendingSafariWrites.keys.sorted() {
            _ = validPendingSafariWrite(for: clientId)
        }
        if pendingSafariWrites.count < pendingBefore {
            // Pushes to those browsers were deferred during the review.
            pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded()
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
        if write.removals == nil,
           let approval = approvedSafariWriteSignatures.removeValue(forKey: clientId),
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
            if previous?.held.impact.signature != impact.signature, reviewWindow.presentedClientId == clientId {
                presentPendingSafariWrite(from: clientId, activate: false)
            }
            return false
        }
        log("Blocked a large Safari bookmark change from [\(clientId)]: \(impact.removed) removed, \(impact.moved) moved and \(impact.modified) modified of \(impact.total) existing items. Nothing was written — asking user to confirm.")
        // An open review of this browser is updated in place without taking
        // focus or posting another notification (the user may still be
        // reorganizing). Another browser's open review is never replaced;
        // this one stays reachable from its notification and the menu bar.
        if reviewWindow.presentedClientId == clientId {
            presentPendingSafariWrite(from: clientId, activate: false)
            return false
        }
        if reviewWindow.presentedClientId == nil {
            presentPendingSafariWrite(from: clientId)
        }
        AppState.shared.notificationService.notifyLargeSafariBookmarkChangeSuspected(
            source: Self.displayName(forClient: clientId),
            clientId: clientId,
            removed: impact.removed,
            moved: impact.moved,
            modified: impact.modified
        )
        return false
    }

    /// A later write from the same browser went through (or was rejected), so
    /// an older held change, its approval and its window no longer describe
    /// anything real.
    private func clearPendingSafariWrite(for clientId: String) {
        approvedSafariWriteSignatures.removeValue(forKey: clientId)
        guard pendingSafariWrites.removeValue(forKey: clientId) != nil else { return }
        BookmarkChangeReviewWindowController.shared.dismiss(ifPresenting: clientId)
    }

    /// Opens the before/after review for a held write (notification, menu bar).
    func presentPendingSafariWrite(from clientId: String, activate: Bool = true) {
        if clientId.hasPrefix("to:") {
            presentPendingBrowserWrite(key: clientId, activate: activate)
            return
        }
        guard let write = validPendingSafariWrite(for: clientId) else {
            presentNextPendingSafariWrite()
            return
        }
        let reviewed = write.held.impact
        BookmarkChangeReviewWindowController.shared.present(
            clientId: clientId,
            destination: .safari(source: Self.displayName(forClient: clientId), keepUpdatesOtherBrowsers: settings.bookmarkSyncStrategy == .twoWayMerge),
            impact: reviewed,
            preview: write.held.preview,
            activate: activate,
            onApply: { [weak self] in self?.applyPendingSafariWrite(from: clientId, reviewedSignature: reviewed.signature) },
            onKeep: { [weak self] in self?.rejectPendingSafariWrite(from: clientId, reviewed: reviewed) }
        )
    }

    private func presentNextPendingSafariWrite() {
        guard BookmarkChangeReviewWindowController.shared.presentedClientId == nil else { return }
        for next in pendingSafariWrites.keys.sorted() where validPendingSafariWrite(for: next) != nil {
            presentPendingSafariWrite(from: next)
            return
        }
        for next in pendingBrowserWrites.keys.sorted() where validPendingBrowserWrite(key: next) != nil {
            presentPendingBrowserWrite(key: next)
            return
        }
    }

    // MARK: Large writes into other browsers

    func recordSentBookmarkMessage(_ message: WSMessage, to clientId: String) {
        guard case .bookmarks = message.payload else { return }
        lastBookmarkMessageByClient[Self.messageRecordKey(clientId, message.category)] = message
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
            if key.hasPrefix("to:rm:"), case .bookmarks(let items)? = write.message.payload {
                // Not lost: re-delivered (and reviewed again) under the new settings.
                keepUndeliveredRemovals(items, for: Self.reviewTarget(key))
            }
            log("Discarded the held bookmark change into [\(Self.reviewTarget(key))] because bookmark sync settings changed.")
            return nil
        }
        return write
    }

    private func clearPendingBrowserWrite(key: String) {
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
        if isRemovalBatch {
            unacknowledgedRemovalBatches.remove(clientId)
            removalBatchTimeouts.removeValue(forKey: clientId)
            // Held for review now: the review owns these items.
            settleKeptRemovals(answeredBy: clientId)
        }
        let key = (isRemovalBatch ? "to:rm:" : "to:") + clientId
        guard let sent = isRemovalBatch ? removalBatch : lastBookmarkMessageByClient[clientId],
              reportedMessageId == nil || reportedMessageId == sent.messageId else {
            log("Ignored a held bookmark change from [\(clientId)] for a superseded sync.")
            return
        }
        let count = { (field: String) in (raw[field]?.value as? Int) ?? 0 }
        let impact = SafariBookmarkService.WriteImpact(
            removed: count("removed"), moved: count("moved"), modified: count("modified"), total: count("total"),
            signature: signature, destructiveSignature: destructive
        )
        if rejectedSafariWriteSignatures[key] == rejectionKey(destructive) {
            clearPendingBrowserWrite(key: key)
            if loggedRejectedSafariWriteSkips.insert(key + destructive).inserted {
                log("Skipped a large bookmark change into [\(clientId)] that the user already chose not to apply.")
            }
            return
        }
        let preview = BookmarkChangePreview(before: reviewNodes(raw["before"]?.value), after: reviewNodes(raw["after"]?.value))
        let previous = validPendingBrowserWrite(key: key)
        pendingBrowserWrites[key] = PendingBrowserWrite(message: sent, impact: impact, preview: preview, settingsFingerprint: bookmarkSettingsFingerprint)
        let reviewWindow = BookmarkChangeReviewWindowController.shared
        if previous?.impact.destructiveSignature == destructive {
            if previous?.impact.signature != signature, reviewWindow.presentedClientId == key {
                presentPendingBrowserWrite(key: key, activate: false)
            }
            return
        }
        log("Blocked a large bookmark change into [\(clientId)]: \(impact.removed) removed, \(impact.moved) moved and \(impact.modified) modified of \(impact.total) existing items. Nothing was written — asking user to confirm.")
        if reviewWindow.presentedClientId == key {
            presentPendingBrowserWrite(key: key, activate: false)
            return
        }
        if reviewWindow.presentedClientId == nil {
            presentPendingBrowserWrite(key: key)
        }
        AppState.shared.notificationService.notifyLargeBrowserBookmarkChangeSuspected(
            target: Self.displayName(forClient: clientId),
            clientId: key,
            removed: impact.removed,
            moved: impact.moved,
            modified: impact.modified
        )
    }

    /// The browser wrote an incoming sync (small, or the approved plan).
    private func handleBrowserWriteResult(_ message: WSMessage, clientId: String) {
        guard case .raw(let raw) = message.payload else { return }
        let messageId = raw["messageId"]?.value as? String
        let isRemovalBatch = messageId != nil && lastBookmarkMessageByClient["rm:" + clientId]?.messageId == messageId
        let isFullSync = messageId == nil || lastBookmarkMessageByClient[clientId]?.messageId == messageId
        // A result for a superseded message settles nothing.
        guard isRemovalBatch || isFullSync else { return }
        if isRemovalBatch {
            unacknowledgedRemovalBatches.remove(clientId)
            removalBatchTimeouts.removeValue(forKey: clientId)
            // Only a batch that was actually applied settles what was kept for
            // it; a failed answer (e.g. its sync folder missing) leaves the
            // kept deletions for the next delivery.
            if (raw["applied"]?.value as? Bool) == true {
                settleKeptRemovals(answeredBy: clientId)
            }
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
        guard let write = validPendingBrowserWrite(key: key) else {
            presentNextPendingSafariWrite()
            return
        }
        let reviewed = write.impact
        BookmarkChangeReviewWindowController.shared.present(
            clientId: key,
            destination: .browser(name: Self.displayName(forClient: key)),
            impact: reviewed,
            preview: write.preview,
            activate: activate,
            onApply: { [weak self] in self?.applyPendingBrowserWrite(key: key, reviewedSignature: reviewed.signature) },
            onKeep: { [weak self] in self?.rejectPendingBrowserWrite(key: key, reviewed: reviewed) }
        )
    }

    private func applyPendingBrowserWrite(key: String, reviewedSignature: String) {
        guard let write = validPendingBrowserWrite(key: key) else {
            log("The reviewed bookmark change into [\(Self.reviewTarget(key))] is no longer pending; nothing was sent.")
            presentNextPendingSafariWrite()
            return
        }
        guard write.impact.signature == reviewedSignature else {
            presentPendingBrowserWrite(key: key)
            return
        }
        clearPendingBrowserWrite(key: key)
        let clientId = Self.reviewTarget(key)
        // The extension recomputes the plan and writes only if it is still
        // exactly the reviewed one; otherwise it reports a new review.
        var message = write.message
        if let latest = lastBookmarkMessageByClient[Self.messageRecordKey(clientId, message.category)], latest.messageId != message.messageId {
            // A newer sync went out meanwhile: it supersedes the reviewed one.
            // Send it unapproved; if it is large too, it is reviewed itself.
            message = latest
        } else {
            message.approvedPlanSignature = reviewedSignature
        }
        if let client = daemon?.connectedClients.first(where: { $0.id == clientId }) {
            if message.category == Self.removalBatchCategory {
                unacknowledgedRemovalBatches.insert(clientId)
                armRemovalBatchTimer(for: clientId)
            }
            daemon?.sendWSMessage(message, to: client)
            log("User approved a large bookmark change into [\(clientId)] (\(write.impact.removed) removed, \(write.impact.moved) moved, \(write.impact.modified) modified).")
        } else if message.category == Self.removalBatchCategory, case .bookmarks(let items)? = message.payload {
            keepUndeliveredRemovals(items, for: clientId)
            log("User approved a large bookmark removal for [\(clientId)], but it is not connected; it is delivered (and reviewed there) when it reconnects.")
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
        // In two-way sync Safari is the reference after "Keep": send its tree
        // so the other browsers converge instead of staying diverged (which
        // would hold every later change). Pushes were deferred meanwhile.
        pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded()
        presentNextPendingSafariWrite()
    }

    /// Called when the user approves the change shown in the review window.
    private func applyPendingSafariWrite(from clientId: String, reviewedSignature: String) {
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
        log("User approved a large Safari bookmark change from [\(clientId)] (\(write.held.impact.removed) removed, \(write.held.impact.moved) moved, \(write.held.impact.modified) modified).")
        prepareSafariForIncomingBookmarkMutation()
        // Write exactly the reviewed result, and only onto the Safari file it
        // was computed from.
        if let removals = write.removals {
            // Removal events: commit the reviewed Safari result, recomputing it
            // if Safari changed meanwhile (same change → write, else ask again).
            let sourceClientId = write.sourceName
            var held = write.held
            if safariBookmarks.commitHeldWrite(held, from: write.sourceName) == nil {
                guard let fresh = safariBookmarks.previewRemovals(removals.map { ($0.id, $0.title, $0.url ?? nil) }) else {
                    log("Could not read Safari bookmarks to apply the reviewed deletions; nothing was written.")
                    presentNextPendingSafariWrite()
                    return
                }
                // Same change → write it; now small → write it like any small batch.
                let acceptable = fresh.impact.signature == reviewedSignature || !fresh.impact.requiresConfirmation
                guard acceptable, safariBookmarks.commitHeldWrite(fresh, from: write.sourceName) != nil else {
                    log("Safari bookmarks changed while the review was open; asking again.")
                    holdLargeSafariWrite(PendingSafariWrite(sourceName: write.sourceName, held: fresh, removals: removals), clientId: clientId)
                    return
                }
                held = fresh
            }
            lastNetworkSyncTime = Date()
            log("Applied \(removals.count) reviewed bookmark deletion events from [\(sourceClientId)] (\(held.impact.removed) Safari items).")
            applyBookmarkRemovals(removals, clientId: sourceClientId, safariAlreadyWritten: true)
            presentNextPendingSafariWrite()
            return
        }
        if clientId.hasPrefix(Self.cleanupReviewKey) {
            if let count = safariBookmarks.commitHeldWrite(write.held, from: write.sourceName) {
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
            if let count = safariBookmarks.commitHeldWrite(write.held, from: write.sourceName) {
                lastNetworkSyncTime = Date()
                finishApprovedSafariWrite(count)
            } else {
                // Safari changed during the review: recompute the restore; the
                // same change is written, a different one is reviewed again.
                let count = safariBookmarks.applyBookmarks(restore.bookmarks, from: write.sourceName, isFullMirror: restore.replacing, guardLargeChanges: true)
                if count == SafariBookmarkService.blockedLargeChange, let held = safariBookmarks.lastBlockedWrite {
                    guard held.impact.signature == reviewedSignature,
                          let committed = safariBookmarks.commitHeldWrite(held, from: write.sourceName) else {
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
        if let count = safariBookmarks.commitHeldWrite(write.held, from: write.sourceName) {
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
                // Recompute the deduplication from Safari's current file now.
                pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded()
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
            pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded()
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

    /// Removal events for other browsers go out as one batch per browser. Its
    /// extension dry-runs the whole batch (subtrees included) and holds it for
    /// review when large, exactly like a full sync. A batch for a browser
    /// whose previous batch is still held is merged into it, so no held
    /// deletion is lost by being superseded.
    func sendBookmarkRemovalBatch(_ items: [Bookmark], browsers: Set<Browser>? = nil, excluding excludedId: String? = nil, onlyClientId: String? = nil) {
        guard let daemon, !items.isEmpty else { return }
        for client in daemon.connectedClients
        where client.browser != .safari
            && settings.bookmarkParticipatingBrowsers.contains(client.browser)
            && client.id != excludedId
            && (onlyClientId == nil || client.id == onlyClientId)
            && (browsers?.contains(client.browser) ?? true) {
            guard mayWriteBookmarks(to: client) else { continue }
            var batch = items
            // Merge with a batch still held or not yet answered, so it is not
            // superseded and lost.
            let previousKey = Self.messageRecordKey(client.id, Self.removalBatchCategory)
            if pendingBrowserWrites["to:rm:" + client.id] != nil || unacknowledgedRemovalBatches.contains(client.id),
               let previous = lastBookmarkMessageByClient[previousKey], case .bookmarks(let earlier) = previous.payload {
                batch = earlier + items.filter { item in !earlier.contains { $0.id == item.id } }
            }
            var message = WSMessage(type: .sync, site: "*", category: Self.removalBatchCategory, payload: .bookmarks(batch),
                                    messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
            message.targetBookmarkFolder = settings.bookmarkFolder(for: client.browser)
            recordSentBookmarkMessage(message, to: client.id)
            unacknowledgedRemovalBatches.insert(client.id)
            armRemovalBatchTimer(for: client.id)
            daemon.sendWSMessage(message, to: client)
        }
    }

    static let removalBatchCategory = "bookmarks_removed_batch"
    static let bookmarkPlanCapability = "bookmarkPlan"

    private var notifiedOutdatedExtensions = Set<String>()
    private lazy var lastSettingsFingerprintSeen = bookmarkSettingsFingerprint

    /// Bookmark writes go only to extensions that dry-run them and hold large
    /// changes for review. An older extension would write anything it gets
    /// unreviewed, so it receives nothing until it is updated (said once).
    /// Safari is written natively; its extension never applies bookmarks.
    func mayWriteBookmarks(to client: ConnectedClient) -> Bool {
        if client.browser == .safari { return false }
        if client.capabilities.contains(Self.bookmarkPlanCapability) { return true }
        if notifiedOutdatedExtensions.insert(client.id).inserted {
            log("Bookmark sync to [\(client.id)] is paused: its extension is outdated and cannot review large changes.")
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

    /// A backup restore into Safari, reviewed like any other large write.
    /// Returns false if it is held for review.
    @discardableResult
    func applyRestoreToSafari(_ bookmarks: [SyncBookmark], replacing: Bool) -> Bool {
        // Starting a restore is a new, explicit request: an earlier "Keep"
        // on a restore must not silently skip it.
        rejectedSafariWriteSignatures.removeValue(forKey: Self.restoreReviewKey)
        recordInternalWrite()
        let count = safariBookmarks.applyBookmarks(bookmarks, from: "Backup Restore", isFullMirror: replacing, guardLargeChanges: true)
        if count == SafariBookmarkService.blockedLargeChange, let held = safariBookmarks.lastBlockedWrite {
            holdLargeSafariWrite(PendingSafariWrite(sourceName: "Backup Restore", held: held, restore: (bookmarks, replacing)), clientId: Self.restoreReviewKey)
            return false
        }
        refreshSafariSnapshot()
        return true
    }

    /// Sends a full bookmark sync (e.g. a backup restore) to every
    /// participating browser, remembering it per browser so a large result
    /// held by its extension can be reviewed and approved.
    func broadcastBookmarkSync(_ message: WSMessage) {
        guard let daemon else { return }
        // Same recipients and content as the plain broadcast it replaces.
        for client in daemon.connectedClients where settings.bookmarkParticipatingBrowsers.contains(client.browser) && mayWriteBookmarks(to: client) {
            recordSentBookmarkMessage(message, to: client.id)
            daemon.sendWSMessage(message, to: client)
        }
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
        defer { pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded() }
        refreshSafariSnapshot()
    }

    /// Called when the user taps "Apply Deletions" on the burst-deletion warning.
    func forceApplyPendingBookmarkRemovalBurst(from clientId: String) {
        guard let items = pendingBookmarkRemovalBursts.removeValue(forKey: clientId) else { return }
        log("User approved \(items.count) buffered bookmark deletions from [\(clientId)].")
        applyBookmarkRemovals(removalsInsideSyncFolder(items, clientId: clientId), clientId: clientId)
    }

    /// `items` are already limited to the source's sync folder.
    private func applyBookmarkRemovals(_ items: [Bookmark], clientId: String, safariAlreadyWritten: Bool = false) {
        let eligible = items
        guard !eligible.isEmpty else { return }
        backupService?.addDeletedBookmarks(eligible.map { bm in
            DeletedBookmark(id: bm.id, title: bm.title, url: bm.url ?? nil, parentId: bm.parentId, isFolder: bm.isFolder,
                            deletedAt: Date(), sourceBrowser: clientId, children: nil)
        })
        // Safari is written only when it takes part in bookmark sync.
        let safariParticipates = settings.bookmarkParticipatingBrowsers.contains(.safari) && SandboxAccessManager.shared.hasSafariAccess
        if !safariAlreadyWritten && safariParticipates {
            prepareSafariForIncomingBookmarkMutation()
            for bm in eligible {
                safariBookmarks.removeBookmark(id: bm.id, title: bm.title, url: bm.url ?? nil)
            }
            log("Removed \(eligible.count) deleted items from Safari (triggered by [\(clientId)])")
        }
        if safariAlreadyWritten || safariParticipates { refreshSafariSnapshot() }

        if isSyncing {
            currentManualSyncStats.bookmarkSourceBrowserIds.insert(clientId.components(separatedBy: "-").first ?? clientId)
        } else if AppState.shared.settingsService.general.notifySyncComplete {
            var deletionStats = SyncStats()
            deletionStats.bookmarksDeleted = eligible.filter { !$0.isFolder }.count
            deletionStats.bookmarkFoldersDeleted = eligible.filter(\.isFolder).count
            deletionStats.bookmarkSourceBrowserIds.insert(clientId.components(separatedBy: "-").first ?? clientId)
            AppState.shared.notificationService.notifyAutoSyncComplete(stats: deletionStats, categories: [.bookmarks])
        }

        let isPro = AppState.shared.purchaseService.isProUnlocked
        let shouldSync = (isPro && settings.bookmarkAutoSync && settings.enabledCategories.contains(.bookmarks)) || isSyncing
        guard shouldSync else { return }
        // One batch per browser; each extension reviews it if it is large.
        // NOTE: never saved to GlobalStateStore — point-in-time events.
        sendBookmarkRemovalBatch(eligible, excluding: clientId)
        // Request a fresh sync from all clients to update counts and snapshots accurately.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let req = WSMessage(type: .sync, site: "*", category: "bookmarks", payload: nil, messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
            await MainActor.run {
                self.daemon?.broadcast(req, participatingBrowsers: self.settings.bookmarkParticipatingBrowsers)
            }
        }
    }

    private func sendBookmarkMessage(_ message: WSMessage, to browser: Browser, excluding excludedId: String? = nil) {
        guard let daemon else { return }
        for client in daemon.connectedClients where client.browser == browser && client.id != excludedId && mayWriteBookmarks(to: client) {
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

    private func pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded() {
        guard settings.bookmarkSyncStrategy == .twoWayMerge,
              settings.bookmarkParticipatingBrowsers.contains(.safari) else {
            return
        }

        var safariBookmarksToPush = safariBookmarks.readBookmarks().map {
            Bookmark(
                id: $0.id,
                title: $0.title,
                url: $0.url.flatMap { $0 },
                parentId: $0.parentId,
                isFolder: $0.isFolder,
                sortIndex: $0.sortIndex,
                inBookmarksBar: $0.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }

        if let dedupedBookmarks = BookmarkTreeMerger.deduplicatedBookmarksInFolder(
            tree: safariBookmarksToPush,
            folderPath: settings.bookmarkFolder(for: .safari)
        ), dedupedBookmarks.count != safariBookmarksToPush.count {
            let syncBookmarks = dedupedBookmarks.compactMap { bookmark -> SyncBookmark? in
                let url = bookmark.url.flatMap { $0 }
                if !bookmark.isFolder && url == nil { return nil }
                return SyncBookmark(
                    id: bookmark.id,
                    title: bookmark.title,
                    url: url,
                    parentId: bookmark.parentId,
                    isFolder: bookmark.isFolder,
                    sortIndex: bookmark.sortIndex,
                    inBookmarksBar: bookmark.inBookmarksBar ?? false,
                    dateAdded: bookmark.dateAdded
                )
            }
            let removedCount = safariBookmarksToPush.count - dedupedBookmarks.count
            let echoGuardBefore = (network: lastNetworkSyncTime, backup: suppressSafariPreSyncBackupUntil)
            prepareSafariForIncomingBookmarkMutation()
            recordInternalWrite()
            let writeCount = safariBookmarks.applyBookmarks(syncBookmarks, from: "safari", isFullMirror: true, guardLargeChanges: true)
            if writeCount == SafariBookmarkService.blockedLargeChange, let held = safariBookmarks.lastBlockedWrite {
                lastNetworkSyncTime = echoGuardBefore.network
                suppressSafariPreSyncBackupUntil = echoGuardBefore.backup
                // Deduplication is still a mass removal. Unless the user already
                // approved exactly this one, Safari stays as is and its current,
                // unchanged tree is what gets pushed this round.
                if holdLargeSafariWrite(PendingSafariWrite(sourceName: "safari", held: held), clientId: "Safari") {
                    // The approved deduplication was written and its result
                    // already pushed by finishApprovedSafariWrite.
                    return
                }
            }
            if writeCount == SafariBookmarkService.blockedLargeChange {
                // Held for review; nothing to do this round.
            } else if writeCount >= 0 {
                safariBookmarksToPush = safariBookmarks.readBookmarks().map {
                    Bookmark(
                        id: $0.id,
                        title: $0.title,
                        url: $0.url.flatMap { $0 },
                        parentId: $0.parentId,
                        isFolder: $0.isFolder,
                        inBookmarksBar: $0.inBookmarksBar,
                        dateAdded: Date(),
                        sourceBrowser: .safari
                    )
                }
                log("Removed \(removedCount) duplicate Safari bookmarks inside the selected sync folder before final convergence.")
            } else {
                safariBookmarksToPush = dedupedBookmarks
                log("Prepared duplicate-free Safari bookmark payload, but Safari native write did not complete.")
            }
            if writeCount >= 0 {
                clearPendingSafariWrite(for: "Safari")
                rejectedSafariWriteSignatures.removeValue(forKey: "Safari")
            }
        } else {
            // Nothing to deduplicate any more; a held deduplication is obsolete.
            clearPendingSafariWrite(for: "Safari")
        }

        guard !safariBookmarksToPush.isEmpty,
              let adjustedBookmarks = folderAdjustedBookmarksForSource(safariBookmarksToPush, browser: .safari) else {
            return
        }

        var message = WSMessage(
            type: .sync,
            browser: Browser.safari.rawValue,
            site: "*",
            category: SyncCategory.bookmarks.rawValue,
            payload: .bookmarks(adjustedBookmarks),
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
        message.isFullMirror = false

        for browser in settings.bookmarkParticipatingBrowsers where browser != .safari {
            sendBookmarkMessage(message, to: browser)
        }
        log("Pushed final Safari bookmark state to non-Safari participants (\(adjustedBookmarks.count) bookmarks)")
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

    private var pendingSafariRemovalsURL: URL {
        dataDir.appendingPathComponent("pending-safari-bookmark-removals.json")
    }

    private func loadPendingSafariRemovals() {
        guard let data = try? Data(contentsOf: pendingSafariRemovalsURL),
              let saved = try? JSONDecoder().decode([String: [Bookmark]].self, from: data) else { return }
        pendingSafariRemovals = saved
    }

    private func savePendingSafariRemovals() {
        guard let data = try? JSONEncoder().encode(pendingSafariRemovals) else { return }
        do { try data.write(to: pendingSafariRemovalsURL, options: .atomic) }
        catch { log("Could not save pending Safari bookmark removals: \(error.localizedDescription)") }
    }

    func deliverPendingSafariRemovals(to clientId: String) -> Bool {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        guard let browser = Browser(rawValue: browserId),
              let removals = pendingSafariRemovals[browserId], !removals.isEmpty else { return false }
        // A user may have restored a bookmark in Safari while the target was offline.
        // A fresh nonempty read prevents replaying that now-stale removal.
        let currentSafari = safariBookmarks.readBookmarks()
        guard !currentSafari.isEmpty else {
            log("Deferred pending Safari removals for [\(clientId)]: Safari bookmark read was empty.")
            return false
        }
        let toDeliver = removals.filter { removed in
            !currentSafari.contains { current in
                current.id == removed.id ||
                (removed.isFolder && current.isFolder && current.title.caseInsensitiveCompare(removed.title) == .orderedSame) ||
                (!removed.isFolder && current.url.flatMap { $0 }?.lowercased() == removed.url.flatMap { $0 }?.lowercased())
            }
        }
        // Kept until the browser's extension can take them.
        guard let client = daemon?.connectedClients.first(where: { $0.id == clientId }), mayWriteBookmarks(to: client) else { return false }
        // One batch, reviewed by the browser's extension if it is large.
        sendBookmarkRemovalBatch(toDeliver, browsers: [browser])
        pendingSafariRemovals.removeValue(forKey: browserId)
        savePendingSafariRemovals()
        log("Delivered \(toDeliver.count) pending Safari bookmark removals to [\(clientId)]")
        return !toDeliver.isEmpty
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
        if targetCategories.contains(.bookmarks) {
            prepareSafariForIncomingBookmarkMutation()
            runSafariCleanup(safariBookmarks.previewMobileContaminationCleanup(), key: Self.mobileCleanupKey)
        }
        // Read pre-sync Safari bookmarks on all builds (sandbox access handled inside readBookmarks)
        let preSyncSafariBookmarks = targetCategories.contains(.bookmarks) ? safariBookmarks.readBookmarks() : []
        if !preSyncSafariBookmarks.isEmpty { bookmarkCounts["safari"] = preSyncSafariBookmarks.count }
        for category in SyncCategory.allCases where targetCategories.contains(category) {
            await syncCategory(category)
        }
        
        // Wait for clients to respond before ending manual sync window
        // But don't wait at all if no clients connected
        let hasClients = (daemon?.connectedClients.isEmpty == false)
        if hasClients {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }

        if targetCategories.contains(.bookmarks) {
            pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded()
        }

        lastSyncDate = Date()
        isSyncing = false
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
                    // Check for deletions comparing to the last hidden snapshot.
                    // IMPORTANT: We compare by URL (for leaves) and title (for folders), NOT by UUID.
                    // Safari's Bookmarks.plist may regenerate UUIDs when rewritten, so UUID mismatches
                    // do NOT indicate a real deletion. If the URL/title still exists in Safari, it was NOT deleted.
                    if let lastSafariBms = backupService?.getSnapshot(sourceBrowser: "safari") {
                        let currentIds = Set(safariBms.map { $0.id })
                        let currentUrls = Set(safariBms.compactMap { $0.url.flatMap { $0 } }.map { $0.lowercased() })
                        let currentFolderTitles = Set(safariBms.filter { $0.isFolder }.map { $0.title.lowercased() })
                        
                        let deletedBms = lastSafariBms.filter { bm in
                            // Still present by ID → not deleted
                            if currentIds.contains(bm.id) { return false }
                            // Leaf: still present by URL → UUID drift, not a real deletion
                            if let urlOpt = bm.url, let url = urlOpt, currentUrls.contains(url.lowercased()) { return false }
                            // Folder: still present by title → UUID drift, not a real deletion
                            if bm.isFolder && currentFolderTitles.contains(bm.title.lowercased()) { return false }
                            // Truly gone from Safari
                            return true
                        }
                        
                        if !deletedBms.isEmpty {
                            log("Detected \(deletedBms.count) bookmark deletions in Safari, adding to trash...")
                            
                            let deletedItems = buildDeletedBookmarkForest(from: deletedBms, sourceBrowser: "Safari")
                            backupService?.addDeletedBookmarks(deletedItems)

                            if strategy == .twoWayMerge {
                                // Browsers whose extension cannot take removal batches
                                // are treated as offline: their removals wait.
                                let online = Set(daemon?.connectedClients.filter { mayWriteBookmarks(to: $0) }.map(\.browser) ?? [])
                                for browser in settings.bookmarkParticipatingBrowsers where browser != .safari && !online.contains(browser) {
                                    var pending = pendingSafariRemovals[browser.rawValue] ?? []
                                    for bookmark in deletedBms where !pending.contains(where: { $0.id == bookmark.id }) {
                                        pending.append(bookmark)
                                    }
                                    pendingSafariRemovals[browser.rawValue] = pending
                                }
                                savePendingSafariRemovals()
                            }
                            
                            // One batch per browser: each extension dry-runs it
                            // (subtrees included) and holds a large one for review.
                            // NOTE: never saved to GlobalStateStore — point-in-time events.
                            sendBookmarkRemovalBatch(deletedBms)
                            if self.isSyncing {
                                self.currentManualSyncStats.bookmarksDeleted += deletedBms.filter { !$0.isFolder }.count
                                self.currentManualSyncStats.bookmarkFoldersDeleted += deletedBms.filter(\.isFolder).count
                                self.currentManualSyncStats.bookmarkSourceBrowserIds.insert(Browser.safari.id)
                            } else if AppState.shared.settingsService.general.notifySyncComplete {
                                var stats = SyncStats()
                                stats.bookmarksDeleted = deletedBms.filter { !$0.isFolder }.count
                                stats.bookmarkFoldersDeleted = deletedBms.filter(\.isFolder).count
                                stats.bookmarkSourceBrowserIds.insert(Browser.safari.id)
                                AppState.shared.notificationService.notifyAutoSyncComplete(stats: stats, categories: [.bookmarks])
                            }
                        }
                    }

                    let rawBookmarks = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                    
                    if let adjustedBookmarks = folderAdjustedBookmarksForSource(rawBookmarks, browser: .safari),
                       let backupBookmarks = backupBookmarksForSource(rawBookmarks, browser: .safari) {
                        let bookmarks = adjustedBookmarks

                        if !isSyncing, let previous = backupService?.getSnapshot(sourceBrowser: "safari") {
                            var stats = SyncStats()
                            populateAutomaticBookmarkChangeStats(previous: previous, current: bookmarks, stats: &stats)
                            if (stats.bookmarksAdded > 0 || stats.bookmarksModified > 0 ||
                                stats.bookmarkFoldersAdded > 0 || stats.bookmarkFoldersModified > 0),
                               AppState.shared.settingsService.general.notifySyncComplete {
                                stats.bookmarkSourceBrowserIds.insert(Browser.safari.id)
                                AppState.shared.notificationService.notifyAutoSyncComplete(stats: stats, categories: [.bookmarks])
                            }
                        }

                        if isSyncing, let previous = backupService?.getSnapshot(sourceBrowser: "safari") {
                            let previousById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
                            let changed = previousById.count != bookmarks.count || bookmarks.contains { item in
                                guard let old = previousById[item.id] else { return true }
                                return old.title != item.title || old.url != item.url || old.parentId != item.parentId
                            }
                            if changed { currentManualSyncStats.bookmarkSourceBrowserIds.insert(Browser.safari.id) }
                        }

                        backupService?.savePreSyncBackup(
                            bookmarks: backupBookmarks,
                            sourceBrowser: "safari",
                            folderPath: settings.bookmarkFolder(for: .safari)
                        )
                        backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: "safari")
                        bookmarkCounts["safari"] = bookmarks.count
                        
                        var pushMsg = WSMessage(
                            type: .sync,
                            browser: Browser.safari.rawValue,
                            site: "*",
                            category: category.rawValue,
                            payload: .bookmarks(bookmarks),
                            messageId: UUID().uuidString,
                            timestamp: Date().timeIntervalSince1970
                        )
                        pushMsg.isFullMirror = (strategy == .oneWay) // Root selection keeps the old full mirror behavior; targeted folders are handled per receiver.
                        for client in daemon?.connectedClients ?? [] where client.browser != .safari && settings.bookmarkParticipatingBrowsers.contains(client.browser) && !isSafariPushDeferred(to: client.id) {
                            recentSafariPushByClient[client.id] = (bookmarks, Date())
                        }
                        broadcastBookmarkMessage(pushMsg)
                        log("Pushed \(bookmarks.count) Safari bookmarks to clients")
                        
                        // After pushing, update expected counts for all non-Safari receiving browsers
                        // so the UI reflects what was just sent (avoids stale counts after sync)
                        let targetDir = dataDir.appendingPathComponent("bookmarks")
                        for browser in settings.bookmarkParticipatingBrowsers where browser.id != "safari" && !isSafariPushDeferred(to: "\(browser.id)-main") {
                            bookmarkCounts[browser.id] = bookmarks.count
                            // Also persist this pushed state so it survives app restart
                            save(bookmarks, to: targetDir.appendingPathComponent("\(browser.id)-main.json"))
                        }
                    } else {
                        log("Skipped Safari bookmark push because its selected sync folder is missing; continuing with other browsers.")
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
        
        var filteredMessage = message
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
            // Only the removal batch this answers (a full sync's report, or one
            // without an ID from an older extension, concerns no batch here).
            if case .raw(let raw)? = message.payload,
               let answered = raw["messageId"]?.value as? String,
               answered == lastBookmarkMessageByClient["rm:" + clientId]?.messageId {
                abandonRemovalBatch(for: clientId, reason: "sync folder missing")
            }
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

        if isBookmarkCategory && strategy == .oneWay && !isClient(clientId, from: sourceBrowser) {
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
        if strategy == .oneWay && category == "bookmarks" {
            // In one-way sync, the target should exactly mirror the source.
            // Setting isFullMirror = true ensures the target prunes local items not present in the payload.
            filteredMessage.isFullMirror = true
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
            saveSnapshotAliases(bookmarks: bms, clientId: clientId)
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
                return
            }
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            let browser = Browser(rawValue: browserId)
            guard let sourceBrowserForFolder = browser else {
                return
            }

            // A full snapshot is state, not deletion authority.  In particular, do not
            // filter it through local deletion tombstones before applying it: Chrome
            // legitimately echoes Safari's tree after a native write, but Safari UUIDs
            // differ from Chrome's.  Filtering that echo can remove its parent folders
            // and leave otherwise valid children to be recreated at a browser root.
            // Explicit `bookmarks_removed` messages below remain the only deletion path.
            guard let sourceAdjustedBookmarks = folderAdjustedBookmarksForSource(bms, browser: sourceBrowserForFolder) else {
                return
            }
            let previousForDeletion = BookmarkTreeMerger.extractExistingSubtreeAsRoot(
                sourceTree: preSyncAutoBookmarks,
                folderPath: settings.bookmarkFolder(for: sourceBrowserForFolder)
            ) ?? preSyncAutoBookmarks
            processDeletedBookmarksFromFullSnapshot(previous: previousForDeletion, current: sourceAdjustedBookmarks, from: clientId)
            saveSnapshotAliases(bookmarks: bms, clientId: clientId)
            filteredMessage.payload = .bookmarks(sourceAdjustedBookmarks)
        }

        if category == "bookmarks_removed" {
            if case .bookmarksRemoved(let bm) = filteredMessage.payload {
                handleIncomingBookmarkRemoval(bm, clientId: clientId)
            }
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
                    // A full tree is a state refresh, not an event log. It is
                    // used for content/order sync but must never manufacture
                    // add/delete notifications from transient differences.
                    // It can still safely report an actual rename, move, or
                    // reordering of a bookmark that exists in both snapshots.
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
                    if currentMessageSafariWriteWasHeld || isAwaitingReview(of: clientId) {
                        // Safari's write of this tree awaits review (or was
                        // refused); other browsers must not receive it either.
                        log("Did not forward bookmarks from [\(clientId)] to other browsers while the change awaits review.")
                    } else {
                        broadcastBookmarkMessage(filteredMessage, excluding: clientId)
                    }
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

    private func processDeletedBookmarksFromFullSnapshot(previous: [Bookmark], current: [Bookmark], from clientId: String) {
        guard !clientId.lowercased().contains("safari"),
              !previous.isEmpty,
              !current.isEmpty else { return }
        // A complete tree is not a deletion event. Browsers can briefly omit
        // entries while moving/reordering them, and browser-owned roots are
        // represented differently across snapshots. Inferring deletion here
        // previously turned a harmless move into a destructive broadcast.
        // Explicit `bookmarks_removed` events are the sole deletion authority.
        log("Ignored possible deletions from [\(clientId)] full snapshot; waiting for an explicit bookmarks_removed event.")
    }

    private func bookmarkURL(_ bookmark: Bookmark) -> String? {
        bookmark.url.flatMap { $0 }
    }

    /// Full bookmark trees are state refreshes, not event logs. They may omit
    /// a root or briefly differ while a browser is writing, so automatic
    /// notifications may only report safe updates to a bookmark found in both
    /// snapshots. Explicit `bookmarks_removed` messages remain the sole
    /// source of deletion notifications.
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
        let reorderedBookmarks = reorderedKeys(
            previous: previous,
            current: current,
            previousParents: previousParentPaths,
            currentParents: currentParentPaths,
            key: { bookmarkURL($0)?.lowercased() }
        )
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
        let reorderedFolders = reorderedKeys(
            previous: Array(previousFolders.values),
            current: Array(currentFolders.values),
            previousParents: previousParentPaths,
            currentParents: currentParentPaths,
            key: { $0.id }
        )
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

        // A bookmark the user manually restored still matches its old tombstone
        // (matched by URL/title, not id) for up to 24h, which would otherwise
        // silently strip it back out of every incoming sync as "still deleted".
        backupService?.resurrectDeletedBookmarks(seenIn: bookmarks)

        let rootIds = Set(["0", "1", "2", "3"])
        let bookmarksById = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childrenByParent = Dictionary(grouping: bookmarks, by: { $0.parentId ?? "" })
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        let browser = Browser(rawValue: browserId)
        let selectedFolderIds: Set<String> = {
            guard let browser, let folder = settings.bookmarkFolder(for: browser) else { return [] }
            return BookmarkTreeMerger.idsInFolderIncludingRoot(tree: bookmarks, folderPath: folder)
        }()

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
            if !selectedFolderIds.contains(bookmark.id), isDeletedByTombstone(bookmark) { return true }
            return false
        }

        func shouldDropDescendants(of bookmark: Bookmark) -> Bool {
            if selectedFolderIds.contains(bookmark.id) { return false }
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
            let isPro = AppState.shared.purchaseService.isProUnlocked
            let shouldSyncToSafari = ((isPro && settings.bookmarkAutoSync && settings.enabledCategories.contains(.bookmarks)) || isSyncing)
            
            // Also write natively into Safari if the source is a Chromium browser, AND the category is an actual sync (not a backup)
            if shouldSyncToSafari && category != "bookmark_backup" && !clientId.lowercased().contains("safari") && settings.bookmarkParticipatingBrowsers.contains(.safari) {
                // Safari writes are gated by the security-scoped bookmark
                // that the user granted via requestSafariAccess(). applyBookmarks() and
                // readBookmarks() both call withSafariAccess internally.
                if SandboxAccessManager.shared.hasSafariAccess, isAwaitingReview(of: clientId) {
                    // Its tree still shows what is under review; neither Safari
                    // nor the other browsers take it until the user decides.
                    currentMessageSafariWriteWasHeld = true
                    log("Did not merge bookmarks from [\(clientId)] while a change to it awaits review.")
                } else if SandboxAccessManager.shared.hasSafariAccess {
                    let strategy = settings.bookmarkSyncStrategy
                    let sourceBrowser = settings.bookmarkSourceBrowser
                    if !(strategy == .oneWay && sourceBrowser == .safari) {
                        var finalSyncBookmarks: [SyncBookmark] = []
                        var finalIsFullMirror = isFullMirror
                        
                        let sourceBrowserId = clientId.components(separatedBy: "-").first ?? clientId
                        let targetPreparedBookmarks = Browser(rawValue: sourceBrowserId).map {
                            bookmarksPreparedForTarget(bookmarks, sourceBrowser: $0, targetBrowser: .safari)
                        } ?? bookmarks

                        if let targetFolder = settings.bookmarkFolder(for: .safari) {
                            let safariTargetBms = safariBookmarks.readBookmarks().map { b in
                                Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                            }
                            let mergedBookmarks = strategy == .oneWay
                                ? BookmarkTreeMerger.replaceExistingFolderContents(sourceTree: targetPreparedBookmarks, targetTree: safariTargetBms, targetFolderPath: targetFolder)
                                : BookmarkTreeMerger.mergeIntoExistingFolder(sourceTree: targetPreparedBookmarks, targetTree: safariTargetBms, targetFolderPath: targetFolder)
                            guard let finalBookmarksToSend = mergedBookmarks else {
                                markMissingBookmarkFolder(.safari, folder: targetFolder)
                                return
                            }
                            finalIsFullMirror = strategy == .oneWay
                            finalSyncBookmarks = finalBookmarksToSend.compactMap { b -> SyncBookmark? in
                                let urlStr: String?
                                if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                                if !b.isFolder && urlStr == nil { return nil }
                                return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar ?? false, dateAdded: b.dateAdded)
                            }
                    } else {
                        finalSyncBookmarks = targetPreparedBookmarks.compactMap { b -> SyncBookmark? in
                                let urlStr: String?
                                if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                                if !b.isFolder && urlStr == nil { return nil }
                                return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar ?? false, dateAdded: b.dateAdded)
                            }
                        }
                        
                        let safariBeforeWrite = isSyncing ? safariBookmarks.readBookmarks() : []
                        let echoGuardBefore = (network: lastNetworkSyncTime, backup: suppressSafariPreSyncBackupUntil)
                        prepareSafariForIncomingBookmarkMutation()
                        let sourceName = clientId.components(separatedBy: "-").first ?? clientId
                        self.lastNetworkSyncTime = Date()
                        let count = safariBookmarks.applyBookmarks(finalSyncBookmarks, from: sourceName, isFullMirror: finalIsFullMirror, guardLargeChanges: true)
                        if count == SafariBookmarkService.blockedLargeChange, let held = safariBookmarks.lastBlockedWrite {
                            // Nothing was written: genuine Safari edits must not be
                            // mistaken for echoes, nor pre-sync backups suppressed.
                            lastNetworkSyncTime = echoGuardBefore.network
                            suppressSafariPreSyncBackupUntil = echoGuardBefore.backup
                            currentMessageSafariWriteWasHeld = !holdLargeSafariWrite(PendingSafariWrite(sourceName: sourceName, held: held), clientId: clientId)
                            return
                        }
                        clearPendingSafariWrite(for: clientId)
                        // Only an actual write shows the browser is back in line; a
                        // no-op (nothing new to add) says nothing about the refusal.
                        if count > 0, rejectedSafariWriteSignatures.removeValue(forKey: clientId) != nil {
                            // The browser no longer implies the refused change.
                            log("Bookmark sync from [\(clientId)] is back in line with Safari; the earlier decision to keep Safari unchanged no longer applies.")
                        }
                        if count >= 0 {
                            log("Wrote \(count) bookmarks into Safari natively (App Store)")
                            let freshSafariBms = safariBookmarks.readBookmarks()
                            if isSyncing {
                                let beforeById = Dictionary(uniqueKeysWithValues: safariBeforeWrite.map { ($0.id, $0) })
                                let afterById = Dictionary(uniqueKeysWithValues: freshSafariBms.map { ($0.id, $0) })
                                let changed = beforeById.count != afterById.count || afterById.contains { id, item in
                                    guard let previous = beforeById[id] else { return true }
                                    return previous.title != item.title || previous.url != item.url || previous.parentId != item.parentId
                                }
                                if changed { currentManualSyncStats.bookmarkSourceBrowserIds.insert(sourceName) }
                            }
                            if !freshSafariBms.isEmpty {
                                // Same folder-adjusted form Safari sync diffs against.
                                refreshSafariSnapshot()
                            }
                        }
                    }
                } else {
                    log("Skipping Safari bookmark write: no folder access granted yet")
                }
            }
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

// MARK: - Sync Log Entry

struct SyncLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}
