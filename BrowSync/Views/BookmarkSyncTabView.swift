// BookmarkSyncTabView.swift
// BrowSync — Bookmark Sync Tab

import SwiftUI

@MainActor
private func openBookmarkManager(for browser: Browser, appState: AppState) {
    let managerURL: URL?
    switch browser.id {
    case "chrome", "arc", "orion", "helium", "browseros":
        managerURL = URL(string: "chrome://bookmarks")
    case "edge":
        managerURL = URL(string: "edge://favorites")
    case "brave":
        managerURL = URL(string: "brave://bookmarks")
    case "firefox":
        managerURL = nil
    case "vivaldi":
        managerURL = URL(string: "vivaldi://bookmarks")
    case "opera":
        managerURL = URL(string: "opera://bookmarks")
    case "yandex":
        managerURL = URL(string: "browser://bookmarks")
    default:
        managerURL = nil
    }

    let appURL = appState.browserInfos.first(where: { $0.browser == browser })?.appURL ?? browser.appURL
    if let managerURL, let appURL {
        NSWorkspace.shared.open([managerURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    } else if let appURL {
        NSWorkspace.shared.open(appURL)
    }
}

struct BookmarkSyncTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupService: BackupService
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var isSyncing = false
    @State private var showSuccess = false
    @State private var showUpgradeAlert = false
    @State private var showSandboxAlert = false
    @State private var showAutoSyncUpgradeAlert = false
    @State private var showRecentlyDeletedWindow = false
    @State private var showRecentBackupsWindow = false
    
    @State private var showFolderManager = false
    @State private var handledFolderManagerOpenRequest = 0
    @State private var handledRecentBackupsOpenRequest = 0
    @State private var hasMissingManagedFolder = false
    
    @StateObject private var sandboxManager = SandboxAccessManager.shared
    
    private var syncSettings: Binding<SyncSettings> {
        Binding(
            get: { appState.settingsService.syncSettings },
            set: {
                appState.objectWillChange.send()
                appState.settingsService.syncSettings = $0
                appState.settingsService.save()
            }
        )
    }
    
    private var availableBrowsers: [BrowserInfo] {
        return appState.browserInfos.filter { $0.isInstalled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "Bookmark Sync Title", bundle: langBundle.bundle))
                    .font(.title2.bold())
                
                Spacer()
                
                Toggle(String(localized: "Enable Bookmark Sync", bundle: langBundle.bundle), isOn: Binding(
                    get: { syncSettings.enabledCategories.wrappedValue.contains(.bookmarks) },
                    set: { enabled in
                        if enabled {
                            syncSettings.wrappedValue.enabledCategories.insert(.bookmarks)
                        } else {
                            syncSettings.wrappedValue.enabledCategories.remove(.bookmarks)
                        }
                    }
                ))
                .toggleStyle(.switch)
                
                Button {
                    Task {
                        isSyncing = true
                        await appState.sync(categories: [.bookmarks])
                        isSyncing = false
                        showSuccess = true
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        showSuccess = false
                    }
                } label: {
                    if isSyncing || appState.syncService.isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Syncing...", bundle: langBundle.bundle))
                        }
                    } else if showSuccess {
                        Label(String(localized: "Sync Complete", bundle: langBundle.bundle), systemImage: "checkmark.circle.fill")
                    } else {
                        Label(String(localized: "Sync Now", bundle: langBundle.bundle), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(showSuccess ? .green : .accentColor)
                .disabled(isSyncing || appState.syncService.isSyncing || showSuccess || !syncSettings.enabledCategories.wrappedValue.contains(.bookmarks))
            }
            .padding()

            Form {
                bookmarkBackupWarningSection
                participatingBrowsersSection
                syncStrategySection
                safariFullDiskAccessSection
                recentBackupsSection
                recentlyDeletedSection
            }
            .formStyle(.grouped)
            .disabled(!syncSettings.enabledCategories.wrappedValue.contains(.bookmarks))
            .alert(String(localized: "Professional Required", bundle: langBundle.bundle), isPresented: $showUpgradeAlert) {
                Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "Free version supports up to %d sync browsers. Unlock Professional for unlimited browsers.", bundle: langBundle.bundle), ProLimits.freeSyncBrowserCount))
            }
            .alert(String(localized: "Professional Required", bundle: langBundle.bundle), isPresented: $showAutoSyncUpgradeAlert) {
                Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(localized: "Real-time auto sync is a Professional feature. Unlock Professional to enable it.", bundle: langBundle.bundle))
            }
            .sheet(isPresented: $showRecentlyDeletedWindow) {
                RecentlyDeletedBookmarksWindow(langBundle: langBundle.bundle)
                    .environmentObject(appState)
                    .environmentObject(backupService)
            }
            .sheet(isPresented: $showRecentBackupsWindow) {
                RecentBookmarkBackupsWindow(langBundle: langBundle.bundle)
                    .environmentObject(appState)
                    .environmentObject(backupService)
            }
        }
        .onAppear {
            refreshMissingManagedFolderState()
            handleFolderManagerOpenRequest()
            handleRecentBackupsOpenRequest()
        }
        .onChange(of: syncSettings.wrappedValue.bookmarkParticipatingBrowsers) { _ in
            refreshMissingManagedFolderState()
        }
        .onChange(of: syncSettings.wrappedValue.bookmarkSyncFolders) { _ in
            refreshMissingManagedFolderState()
        }
        .onChange(of: appState.syncService.missingBookmarkFolders) { _ in
            refreshMissingManagedFolderState()
        }
        .onReceive(appState.backupService.$lastSnapshotUpdate) { _ in
            refreshMissingManagedFolderState()
        }
        .onChange(of: appState.bookmarkFolderManagerOpenRequest) { _ in
            handleFolderManagerOpenRequest()
        }
        .onChange(of: appState.recentBookmarkBackupsOpenRequest) { _ in
            handleRecentBackupsOpenRequest()
        }
    }

    private var bookmarkBackupWarningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Bookmark Backup Warning Header", bundle: langBundle.bundle), systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text(String(localized: "Bookmark Backup Warning Detail", bundle: langBundle.bundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var participatingBrowsersSection: some View {
        Section(String(localized: "Participating Browsers", bundle: langBundle.bundle)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(availableBrowsers) { info in
                        Toggle(isOn: participatingBrowserBinding(for: info.browser)) {
                            browserToggleLabel(for: info)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
#if APP_STORE
            if !sandboxManager.hasSafariAccess {
                Text(String(localized: "Safari requires folder access due to Sandbox restrictions.", bundle: langBundle.bundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
#endif
        }
    }

    private var syncStrategySection: some View {
        Section(String(localized: "Sync Strategy", bundle: langBundle.bundle)) {
            bookmarkStrategyPicker
            oneWaySourcePicker
            syncFolderRow
            autoSyncToggle
        }
    }

    private var bookmarkStrategyPicker: some View {
        Picker(String(localized: "Bookmark Strategy", bundle: langBundle.bundle), selection: syncSettings.bookmarkSyncStrategy) {
            ForEach(BookmarkSyncStrategy.allCases) { strategy in
                Text(String(localized: String.LocalizationValue(strategy.displayName), bundle: langBundle.bundle))
                    .tag(strategy)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var oneWaySourcePicker: some View {
        if syncSettings.bookmarkSyncStrategy.wrappedValue == .oneWay {
            Picker(String(localized: "Bookmark Source Browser", bundle: langBundle.bundle), selection: syncSettings.bookmarkSourceBrowser) {
                ForEach(availableBrowsers) { info in
                    HStack(spacing: 6) {
                        AppIconImage(appURL: info.appURL)
                        Text(info.displayName)
                    }
                    .tag(info.browser)
                }
            }
            .pickerStyle(.menu)

#if !APP_STORE
            if syncSettings.bookmarkSourceBrowser.wrappedValue == .safari && !appState.hasFullDiskAccess {
                safariPrivacyWarning(detailKey: "Safari privacy warning", includeRestartNote: true)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.vertical, 4)
            }
#endif
        }
    }

    private var syncFolderRow: some View {
        HStack {
            Text(String(localized: "Sync Folder", bundle: langBundle.bundle))
            Spacer()
            Button {
                showFolderManager = true
            } label: {
                HStack(spacing: 6) {
                    if hasMissingManagedFolder {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(String(localized: "Manage Folders", bundle: langBundle.bundle))
                }
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showFolderManager) {
            BookmarkFolderManagementWindow(langBundle: langBundle.bundle)
                .environmentObject(appState)
        }
        .onChange(of: syncSettings.bookmarkSyncStrategy.wrappedValue) { _ in
            appState.settingsService.save()
        }
        .onChange(of: syncSettings.bookmarkSourceBrowser.wrappedValue) { _ in
            appState.settingsService.save()
        }
    }

    private var autoSyncToggle: some View {
        Toggle(isOn: Binding(
            get: { appState.purchaseService.isProUnlocked && syncSettings.bookmarkAutoSync.wrappedValue },
            set: { enabled in
                guard appState.purchaseService.isProUnlocked else {
                    showAutoSyncUpgradeAlert = true
                    syncSettings.bookmarkAutoSync.wrappedValue = false
                    return
                }
                syncSettings.bookmarkAutoSync.wrappedValue = enabled
            }
        )) {
            HStack(spacing: 6) {
                Text(String(localized: "Real-time Auto Sync", bundle: langBundle.bundle))
                if !appState.purchaseService.isProUnlocked {
                    ProBadge()
                }
            }
        }
    }

    @ViewBuilder
    private var safariFullDiskAccessSection: some View {
#if !APP_STORE
        let needsAccess = !appState.hasFullDiskAccess &&
            (syncSettings.bookmarkSyncStrategy.wrappedValue == .twoWayMerge ||
             (syncSettings.bookmarkSyncStrategy.wrappedValue == .oneWay && syncSettings.bookmarkSourceBrowser.wrappedValue == .safari))
        if needsAccess {
            Section {
                safariPrivacyWarning(detailKey: "Safari privacy warning 2", includeRestartNote: false)
                    .padding(.vertical, 4)
            }
        }
#endif
    }

    private var recentlyDeletedSection: some View {
        Section {
            HStack {
                Text(String(localized: "These bookmarks were deleted recently. You can restore them individually.", bundle: langBundle.bundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "View", bundle: langBundle.bundle)) {
                    showRecentlyDeletedWindow = true
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text(String(localized: "Recently Deleted Bookmarks", bundle: langBundle.bundle))
        }
    }

    private var recentBackupsSection: some View {
        Section {
            HStack {
                Text(String(localized: "A complete copy of each source folder is saved before it is synchronized. The latest 30 backups are kept.", bundle: langBundle.bundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "View", bundle: langBundle.bundle)) {
                    showRecentBackupsWindow = true
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text(String(localized: "Recent Automatic Backups", bundle: langBundle.bundle))
        }
    }

    private func participatingBrowserBinding(for browser: Browser) -> Binding<Bool> {
        Binding(
            get: { syncSettings.bookmarkParticipatingBrowsers.wrappedValue.contains(browser) },
            set: { isParticipating in
                if isParticipating {
                    guard appState.purchaseService.isProUnlocked ||
                            syncSettings.wrappedValue.bookmarkParticipatingBrowsers.count < ProLimits.freeSyncBrowserCount else {
                        showUpgradeAlert = true
                        return
                    }
                    syncSettings.wrappedValue.bookmarkParticipatingBrowsers.insert(browser)
                } else {
                    syncSettings.wrappedValue.bookmarkParticipatingBrowsers.remove(browser)
                }
                appState.settingsService.save()
                appState.broadcastSettings()
            }
        )
    }

    private func safariPrivacyWarning(detailKey: String, includeRestartNote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text(String(localized: "Cannot read Safari bookmarks", bundle: langBundle.bundle))
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            Text(String(localized: String.LocalizationValue(detailKey), bundle: langBundle.bundle))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(String(localized: "Grant in System Settings", bundle: langBundle.bundle)) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "Already granted, refresh", bundle: langBundle.bundle)) {
                    appState.checkFullDiskAccess()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if includeRestartNote {
                Text(String(localized: "Note restart", bundle: langBundle.bundle))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handleFolderManagerOpenRequest() {
        guard appState.bookmarkFolderManagerOpenRequest != handledFolderManagerOpenRequest else { return }
        handledFolderManagerOpenRequest = appState.bookmarkFolderManagerOpenRequest
        showFolderManager = true
    }

    private func handleRecentBackupsOpenRequest() {
        guard appState.recentBookmarkBackupsOpenRequest != handledRecentBackupsOpenRequest else { return }
        handledRecentBackupsOpenRequest = appState.recentBookmarkBackupsOpenRequest
        showRecentBackupsWindow = true
    }

    private func refreshMissingManagedFolderState() {
        let participants = syncSettings.bookmarkParticipatingBrowsers.wrappedValue
        hasMissingManagedFolder = participants.contains { browser in
            if appState.syncService.missingBookmarkFolders[browser.rawValue] != nil { return true }
            return appState.syncService.bookmarkFolderMissing(browser, folder: syncSettings.wrappedValue.bookmarkFolder(for: browser))
        }
    }

    @ViewBuilder
    private func browserToggleLabel(for info: BrowserInfo) -> some View {
        let isParticipating = syncSettings.bookmarkParticipatingBrowsers.wrappedValue.contains(info.browser)
        let hasReachedFreeLimit = syncSettings.bookmarkParticipatingBrowsers.wrappedValue.count >= ProLimits.freeSyncBrowserCount
        let shouldShowProBadge = !appState.purchaseService.isProUnlocked && !isParticipating && hasReachedFreeLimit

        HStack(spacing: 6) {
            if let url = info.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: info.id.sfSymbol)
                    .frame(width: 16, height: 16)
            }
            Text(info.displayName)
            if shouldShowProBadge {
                ProBadge()
            }
            if info.browser == .safari {
#if APP_STORE
                if !sandboxManager.hasSafariAccess {
                    let grantAccessTitle = String(localized: "Grant Access", bundle: langBundle.bundle)
                    Button(action: {
                        sandboxManager.requestSafariAccess { granted in
                            if granted {
                                // Auto-enable Safari if granted successfully
                                syncSettings.wrappedValue.bookmarkParticipatingBrowsers.insert(.safari)
                                appState.settingsService.save()
                                appState.broadcastSettings()
                            }
                        }
                    }) {
                        Text(grantAccessTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
#endif
            }
        }
    }
    
    
    
}

private struct BookmarkBackupTreeNode: Identifiable {
    let bookmark: Bookmark
    let children: [BookmarkBackupTreeNode]?
    var id: String { bookmark.id }
}

private func bookmarkBackupTree(_ bookmarks: [Bookmark]) -> [BookmarkBackupTreeNode] {
    let ids = Set(bookmarks.map(\.id))
    let childrenByParent = Dictionary(grouping: bookmarks, by: { $0.parentId ?? "" })

    func ordered(_ siblings: [Bookmark]) -> [Bookmark] {
        siblings.enumerated().sorted { lhs, rhs in
            let leftOrder = lhs.element.sortIndex ?? lhs.offset
            let rightOrder = rhs.element.sortIndex ?? rhs.offset
            return leftOrder == rightOrder ? lhs.offset < rhs.offset : leftOrder < rightOrder
        }.map(\.element)
    }

    func nodes(parentId: String?) -> [BookmarkBackupTreeNode] {
        ordered(childrenByParent[parentId ?? "", default: []])
            .map { bookmark in
                let children = nodes(parentId: bookmark.id)
                return BookmarkBackupTreeNode(bookmark: bookmark, children: children.isEmpty ? nil : children)
            }
    }

    let roots = ordered(bookmarks.filter { $0.parentId == nil || !ids.contains($0.parentId ?? "") })
    return roots.map { bookmark in
        let children = nodes(parentId: bookmark.id)
        return BookmarkBackupTreeNode(bookmark: bookmark, children: children.isEmpty ? nil : children)
    }
}

private struct BookmarkBackupTreeView: View {
    let nodes: [BookmarkBackupTreeNode]
    @State private var expandedNodeIDs = Set<String>()

    private var allFolderIDs: Set<String> {
        func collect(from nodes: [BookmarkBackupTreeNode]) -> Set<String> {
            var ids = Set<String>()
            for node in nodes {
                let children = node.children ?? []
                guard !children.isEmpty else { continue }
                ids.insert(node.id)
                ids.formUnion(collect(from: children))
            }
            return ids
        }
        return collect(from: nodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                BookmarkBackupTreeRow(node: node, depth: 0, expandedNodeIDs: $expandedNodeIDs)
            }
        }
        .onAppear {
            expandedNodeIDs = allFolderIDs
        }
    }
}

private struct BookmarkBackupTreeRow: View {
    let node: BookmarkBackupTreeNode
    let depth: Int
    @Binding var expandedNodeIDs: Set<String>
    @State private var isHovering = false

    private var children: [BookmarkBackupTreeNode] { node.children ?? [] }
    private var isExpanded: Bool { expandedNodeIDs.contains(node.id) }

    var body: some View {
        if children.isEmpty {
            rowLabel(chevron: nil)
        } else {
            Button {
                if isExpanded {
                    expandedNodeIDs.remove(node.id)
                } else {
                    expandedNodeIDs.insert(node.id)
                }
            } label: {
                rowLabel(chevron: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(children) { child in
                    BookmarkBackupTreeRow(node: child, depth: depth + 1, expandedNodeIDs: $expandedNodeIDs)
                }
            }
        }
    }

    private func rowLabel(chevron: String?) -> some View {
        HStack(spacing: 6) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: node.bookmark.isFolder ? "folder.fill" : "bookmark.fill")
                .foregroundStyle(.secondary)
            Text(node.bookmark.title)
                .foregroundStyle(.primary)
            if !node.bookmark.isFolder, let url = node.bookmark.url ?? nil {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .onHover { isHovering = $0 }
    }
}

struct RecentBookmarkBackupsWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupService: BackupService
    @Environment(\.dismiss) private var dismiss
    let langBundle: Bundle

    @State private var backupToRestore: BookmarkBackup?
    @State private var restoreWillReplace = false
    @State private var restoreResult: BookmarkRestoreResult?
    @State private var backupToDelete: BookmarkBackup?
    @State private var expandedBackupID: String?

    private struct BackupSyncGroup: Identifiable {
        let createdAt: Date
        let backups: [BookmarkBackup]
        var id: String { backups.first?.id ?? UUID().uuidString }
    }

    /// A sync updates participating browsers within the same displayed sync
    /// minute. Historical backups do not carry a transaction ID, so this keeps
    /// all browser backups from one visible sync event together.
    private var backupSyncGroups: [BackupSyncGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: backupService.recentBookmarkBackups) { backup in
            calendar.date(from: calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: backup.createdAt))!
        }
        return grouped.compactMap { minute, backups in
            let sorted = backups.sorted { $0.createdAt > $1.createdAt }
            guard !sorted.isEmpty else { return nil }
            return BackupSyncGroup(createdAt: minute, backups: sorted)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Recent Automatic Backups", bundle: langBundle))
                    .font(.title3.bold())
                Spacer()
            }
            .padding()

            Divider()

            if backupService.recentBookmarkBackups.isEmpty {
                Text(String(localized: "No backups", bundle: langBundle))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Text(String(localized: "Incremental Restore keeps existing bookmarks and adds missing items. Replace Restore clears the selected folder first.", bundle: langBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 12)

                        ForEach(backupSyncGroups) { group in
                            Text(group.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                            ForEach(group.backups) { backup in
                                if expandedBackupID == backup.id {
                                    Section {
                                        BookmarkBackupTreeView(nodes: bookmarkBackupTree(backup.bookmarks))
                                            .padding(.leading, 8)
                                            .padding(.vertical, 8)
                                        Divider()
                                    } header: {
                                        backupRow(backup, expanded: true, showsActions: true)
                                            .background(.background)
                                    }
                                } else {
                                    backupRow(backup, expanded: false, showsActions: false)
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Close", bundle: langBundle)) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .frame(width: 760, height: 560)
        .alert(restoreWillReplace ? String(localized: "Replace Restore", bundle: langBundle) : String(localized: "Incremental Restore", bundle: langBundle), isPresented: Binding(
            get: { backupToRestore != nil },
            set: { if !$0 { backupToRestore = nil } }
        ), presenting: backupToRestore) { backup in
            Button(restoreWillReplace ? String(localized: "Replace Restore", bundle: langBundle) : String(localized: "Incremental Restore", bundle: langBundle), role: restoreWillReplace ? .destructive : nil) {
                restore(backup, replacing: restoreWillReplace)
                backupToRestore = nil
            }
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) { backupToRestore = nil }
        } message: { _ in
            Text(String(localized: restoreWillReplace ? "Replace the current bookmarks in the selected folder with this backup?" : "Add the missing bookmarks from this backup to the selected folder?", bundle: langBundle))
        }
        .alert(String(localized: "Delete", bundle: langBundle), isPresented: Binding(
            get: { backupToDelete != nil },
            set: { if !$0 { backupToDelete = nil } }
        ), presenting: backupToDelete) { backup in
            Button(String(localized: "Delete", bundle: langBundle), role: .destructive) {
                backupService.removeRecentBookmarkBackup(id: backup.id)
                backupToDelete = nil
            }
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) { backupToDelete = nil }
        } message: { _ in
            Text(String(localized: "This backup will be permanently deleted.", bundle: langBundle))
        }
        .alert(String(localized: "Restore completed", bundle: langBundle), isPresented: Binding(
            get: { restoreResult != nil },
            set: { if !$0 { restoreResult = nil } }
        )) {
            Button(String(localized: "OK", bundle: langBundle), role: .cancel) { restoreResult = nil }
        } message: {
            if let result = restoreResult {
                let format = String(localized: "Restore completed. This backup contains %d bookmarks and %d folders, including subfolders. The restored tree was sent to participating browsers.", bundle: langBundle)
                Text(String(format: format, result.bookmarkCount, result.folderCount))
            }
        }
    }

    @ViewBuilder
    private func backupRow(_ backup: BookmarkBackup, expanded: Bool, showsActions: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                expandedBackupID = expanded ? nil : backup.id
            } label: {
                let source = backupSourcePresentation(for: backup)
                let itemCounts = backupItemCounts(backup.bookmarks)
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                    if let appURL = source.appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: source.fallbackSymbol)
                            .frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(source.displayName) / \(backupFolderDisplayName(backup))")
                            .font(.headline)
                        Text(String(format: String(localized: "Backup Contents Summary", bundle: langBundle), itemCounts.bookmarkCount, itemCounts.folderCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsActions {
                Button(String(localized: "Incremental Restore", bundle: langBundle)) {
                    requestRestore(backup, replacing: false)
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Replace Restore", bundle: langBundle)) {
                    requestRestore(backup, replacing: true)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    backupToDelete = backup
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, showsActions ? 0 : 2)
        .contentShape(Rectangle())
    }

    private struct BackupSourcePresentation {
        let displayName: String
        let appURL: URL?
        let fallbackSymbol: String
    }

    private struct BookmarkRestoreResult {
        let bookmarkCount: Int
        let folderCount: Int
    }

    private func requestRestore(_ backup: BookmarkBackup, replacing: Bool) {
        restoreWillReplace = replacing
        backupToRestore = backup
    }

    private func backupItemCounts(_ bookmarks: [Bookmark]) -> (bookmarkCount: Int, folderCount: Int) {
        var seenIDs = Set<String>()
        var bookmarkCount = 0
        var folderCount = 0

        func count(_ nodes: [Bookmark]) {
            for node in nodes where seenIDs.insert(node.id).inserted {
                if node.isFolder {
                    folderCount += 1
                } else {
                    bookmarkCount += 1
                }
                if let children = node.children {
                    count(children)
                }
            }
        }

        count(bookmarks)
        return (bookmarkCount, folderCount)
    }

    private func backupSourcePresentation(for backup: BookmarkBackup) -> BackupSourcePresentation {
        let rawSource = backup.sourceBrowser
        let sourceIdentifier = rawSource.hasSuffix("-main")
            ? String(rawSource.dropLast("-main".count))
            : rawSource

        if let browser = Browser(rawValue: sourceIdentifier.components(separatedBy: "-").first ?? sourceIdentifier) {
            let appURL = appState.browserInfos.first(where: { $0.browser == browser })?.appURL ?? browser.appURL
            return BackupSourcePresentation(
                displayName: appDisplayName(at: appURL) ?? browser.displayName,
                appURL: appURL,
                fallbackSymbol: browser.sfSymbol
            )
        }

        if sourceIdentifier.contains(".") {
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceIdentifier)
            if let displayName = appDisplayName(at: appURL) {
                return BackupSourcePresentation(displayName: displayName, appURL: appURL, fallbackSymbol: "globe")
            }
        }

        return BackupSourcePresentation(displayName: rawSource, appURL: nil, fallbackSymbol: "globe")
    }

    private func appDisplayName(at appURL: URL?) -> String? {
        guard let appURL, let bundle = Bundle(url: appURL) else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    private func backupFolderDisplayName(_ backup: BookmarkBackup) -> String {
        BookmarkFolderPath.displayPath(backup.folderPath, bundle: langBundle)
            ?? String(localized: "Root Directory (All Bookmarks)", bundle: langBundle)
    }

    private func restore(_ backup: BookmarkBackup, replacing: Bool) {
        let safariService = SafariBookmarkService()
        let safariTree = safariService.readBookmarks().map {
            Bookmark(id: $0.id, title: $0.title, url: $0.url, parentId: $0.parentId, isFolder: $0.isFolder, sortIndex: $0.sortIndex, inBookmarksBar: $0.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
        }
        let targetFolder = appState.settingsService.syncSettings.bookmarkFolder(for: .safari)
        // Archive trees retain browser-owned roots so they can be inspected.
        // Never replay those roots: restoring an Edge archive must not create
        // folders named “Bookmarks Bar” inside Chrome or Safari.
        let archivedSelection = BookmarkTreeMerger.extractExistingSubtreeAsRoot(
            sourceTree: backup.bookmarks,
            folderPath: backup.folderPath
        ) ?? backup.bookmarks
        let restoreSource = portableRestoreTree(archivedSelection)
        let safariPayload: [Bookmark]
        if replacing {
            safariPayload = BookmarkTreeMerger.replaceExistingFolderContents(sourceTree: restoreSource, targetTree: safariTree, targetFolderPath: targetFolder) ?? restoreSource
        } else {
            safariPayload = BookmarkTreeMerger.mergeIntoExistingFolder(sourceTree: restoreSource, targetTree: safariTree, targetFolderPath: targetFolder) ?? restoreSource
        }

        let syncBookmarks = safariPayload.compactMap { bookmark -> SyncBookmark? in
            let url = bookmark.url.flatMap { $0 }
            guard bookmark.isFolder || url != nil else { return nil }
            return SyncBookmark(id: bookmark.id, title: bookmark.title, url: url, parentId: bookmark.parentId, isFolder: bookmark.isFolder, sortIndex: bookmark.sortIndex, inBookmarksBar: bookmark.inBookmarksBar ?? false, dateAdded: bookmark.dateAdded)
        }
        appState.syncService.recordInternalWrite()
        _ = safariService.applyBookmarks(syncBookmarks, from: "Backup Restore", isFullMirror: replacing)

        var message = WSMessage(type: .sync, site: "*", category: "bookmarks", payload: .bookmarks(restoreSource), messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
        message.isFullMirror = replacing
        appState.daemon.broadcast(message, participatingBrowsers: appState.settingsService.syncSettings.bookmarkParticipatingBrowsers)
        let itemCounts = backupItemCounts(backup.bookmarks)
        restoreResult = BookmarkRestoreResult(bookmarkCount: itemCounts.bookmarkCount, folderCount: itemCounts.folderCount)
    }

    /// Converts the archival representation back to the portable bookmark
    /// payload used by normal sync. Browser root folders are metadata, not
    /// user folders; only their children are restored to canonical roots.
    private func portableRestoreTree(_ bookmarks: [Bookmark]) -> [Bookmark] {
        func canonicalRootID(for bookmark: Bookmark) -> String? {
            let id = bookmark.id.lowercased()
            if id == "0" { return "0" }
            if id == "1" || id.contains("root-bar") || id.contains("root-favorites") || id.contains("toolbar-root") { return "1" }
            if id == "2" || id.contains("root-menu") || id.contains("root-other") { return "2" }
            if id == "3" || id.contains("root-mobile") { return "3" }
            return nil
        }

        let rootMappings = Dictionary(
            uniqueKeysWithValues: bookmarks.compactMap { bookmark in
                canonicalRootID(for: bookmark).map { (bookmark.id, $0) }
            }
        )

        return bookmarks.compactMap { bookmark in
            if rootMappings[bookmark.id] != nil { return nil }
            var portable = bookmark
            if let parentID = bookmark.parentId, let canonicalParentID = rootMappings[parentID] {
                portable.parentId = canonicalParentID
                portable.inBookmarksBar = canonicalParentID == "1"
            }
            return portable
        }
    }
}

struct RecentlyDeletedBookmarksWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupService: BackupService
    @Environment(\.dismiss) private var dismiss
    let langBundle: Bundle

    @State private var itemToDelete: DeletedBookmark?
    @State private var showingDeleteConfirmation = false
    @State private var showingClearAllConfirmation = false
    @State private var showingRestoreAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Recently Deleted Bookmarks", bundle: langBundle))
                    .font(.title3.bold())
                Spacer()
            }
            .padding()

            Divider()

            Group {
                if backupService.isLoadingDeletedBookmarks {
                    VStack {
                        ProgressView()
                        Text(String(localized: "Loading...", bundle: langBundle))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if backupService.deletedBookmarks.isEmpty {
                    VStack {
                        Text(String(localized: "No deleted bookmarks", bundle: langBundle))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        HStack {
                            Text(String(localized: "These bookmarks were deleted recently. You can restore them individually.", bundle: langBundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Restore All", bundle: langBundle)) {
                                showingRestoreAllConfirmation = true
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)

                            Button(String(localized: "Clear All", bundle: langBundle)) {
                                showingClearAllConfirmation = true
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .font(.caption)
                        }

                        ForEach(backupService.deletedBookmarks) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    HStack(spacing: 6) {
                                        Image(systemName: deletedItemIconName(for: item))
                                            .foregroundStyle(item.isFolder ? .orange : .accentColor)
                                            .accessibilityLabel(deletedItemTypeTitle(for: item))
                                        Text(item.title)
                                            .font(.headline)
                                    }
                                    HStack(spacing: 4) {
                                        Text(deletedItemDetailText(for: item))
                                        Text("•")
                                        Text(item.deletedAt.formatted(date: .numeric, time: .shortened))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(String(localized: "Restore", bundle: langBundle)) {
                                    restoreBookmark(item)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)

                                Button {
                                    itemToDelete = item
                                    showingDeleteConfirmation = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.red)
                                .padding(.leading, 8)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Close", bundle: langBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .frame(width: 720, height: 520)
        .onAppear {
            backupService.loadDeletedItemsIfNeeded()
        }
        .alert(
            String(localized: "Confirm deletion", bundle: langBundle),
            isPresented: $showingDeleteConfirmation,
            presenting: itemToDelete
        ) { item in
            Button(String(localized: "Delete Permanently", bundle: langBundle), role: .destructive) {
                backupService.removeDeletedBookmark(id: item.id)
            }
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "This deleted bookmark will be permanently removed from the trash bin.", bundle: langBundle))
        }
        .alert(
            String(localized: "Confirm Clear All", bundle: langBundle),
            isPresented: $showingClearAllConfirmation
        ) {
            Button(String(localized: "Clear All", bundle: langBundle), role: .destructive) {
                backupService.clearAllDeletedBookmarks()
            }
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "Are you sure you want to permanently delete all bookmarks in the trash bin?", bundle: langBundle))
        }
        .alert(
            String(localized: "Confirm Restore All", bundle: langBundle),
            isPresented: $showingRestoreAllConfirmation
        ) {
            Button(String(localized: "Restore All", bundle: langBundle)) {
                restoreAllBookmarks()
            }
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "Are you sure you want to restore all bookmarks from the trash bin?", bundle: langBundle))
        }
    }

    private func flattenDeletedBookmark(_ item: DeletedBookmark) -> [SyncBookmark] {
        var result = [SyncBookmark(id: item.id, title: item.title, url: item.url, parentId: item.parentId, isFolder: item.isFolder, inBookmarksBar: item.parentId == "1")]
        if let children = item.children {
            for child in children {
                result.append(contentsOf: flattenDeletedBookmark(child))
            }
        }
        return result
    }

    private func deletedItemIconName(for item: DeletedBookmark) -> String {
        item.isFolder ? "folder.fill" : "bookmark.fill"
    }

    private func deletedItemTypeTitle(for item: DeletedBookmark) -> String {
        String(localized: item.isFolder ? "Folder" : "Bookmark", bundle: langBundle)
    }

    private func deletedItemDetailText(for item: DeletedBookmark) -> String {
        if item.isFolder {
            return String(localized: "Folder", bundle: langBundle)
        }
        return item.url ?? String(localized: "Unknown URL", bundle: langBundle)
    }

    private func restoreAllBookmarks() {
#if APP_STORE
        return
#else
        let safariSvc = SafariBookmarkService()
        var currentSafariBookmarks = safariSvc.readBookmarks()

        for item in backupService.deletedBookmarks {
            let newBookmarks = flattenDeletedBookmark(item)
            currentSafariBookmarks.append(contentsOf: newBookmarks)
        }

        appState.syncService.recordInternalWrite()
        safariSvc.applyBookmarks(currentSafariBookmarks, from: "RestoreAll", isFullMirror: false)

        var restoredItems: [SyncBookmark] = []
        for item in backupService.deletedBookmarks {
            restoredItems.append(contentsOf: flattenDeletedBookmark(item))
        }
        let broadcastBookmarks = restoredItems.map { b in
            Bookmark(
                id: b.id,
                title: b.title,
                url: b.url,
                parentId: b.parentId,
                isFolder: b.isFolder,
                inBookmarksBar: b.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }
        let msg = WSMessage(
            type: .sync,
            site: "*",
            category: "bookmarks",
            payload: .bookmarks(broadcastBookmarks),
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
        appState.daemon.broadcast(msg, participatingBrowsers: appState.settingsService.syncSettings.bookmarkParticipatingBrowsers)

        backupService.clearAllDeletedBookmarks()
#endif
    }

    private func restoreBookmark(_ item: DeletedBookmark) {
#if APP_STORE
        return
#else
        let safariSvc = SafariBookmarkService()
        var currentSafariBookmarks = safariSvc.readBookmarks()

        let newBookmarks = flattenDeletedBookmark(item)
        currentSafariBookmarks.append(contentsOf: newBookmarks)

        appState.syncService.recordInternalWrite()
        safariSvc.applyBookmarks(currentSafariBookmarks, from: "Restore", isFullMirror: false)

        let broadcastBookmarks = newBookmarks.map { b in
            Bookmark(
                id: b.id,
                title: b.title,
                url: b.url,
                parentId: b.parentId,
                isFolder: b.isFolder,
                inBookmarksBar: b.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }
        let msg = WSMessage(
            type: .sync,
            site: "*",
            category: "bookmarks",
            payload: .bookmarks(broadcastBookmarks),
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
        appState.daemon.broadcast(msg, participatingBrowsers: appState.settingsService.syncSettings.bookmarkParticipatingBrowsers)

        backupService.removeDeletedBookmark(id: item.id)
#endif
    }
}

// MARK: - Folder Node

struct FolderNode: Identifiable, Hashable {
    let id: String // full path
    let name: String
    var children: [FolderNode]?
}

class FolderNodeClass {
    let name: String
    let fullPath: String
    var children: [String: FolderNodeClass] = [:]
    var orderIndex: Int
    
    init(name: String, fullPath: String, orderIndex: Int) {
        self.name = name
        self.fullPath = fullPath
        self.orderIndex = orderIndex
    }
    
    func toStruct(bundle: Bundle) -> FolderNode {
        let sortedChildren = children.values.sorted { $0.orderIndex < $1.orderIndex }.map { $0.toStruct(bundle: bundle) }
        return FolderNode(id: fullPath, name: BookmarkFolderPath.displayComponent(name, bundle: bundle), children: sortedChildren.isEmpty ? nil : sortedChildren)
    }
}

extension BookmarkSyncTabView {
    static func buildTree(from paths: [String], bundle: Bundle = .main) -> [FolderNode] {
        let root = FolderNodeClass(name: "", fullPath: "", orderIndex: -1)
        for (i, path) in paths.enumerated() {
            let components = path.components(separatedBy: "/")
            var current = root
            var currentPath = ""
            for component in components {
                currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
                if current.children[component] == nil {
                    current.children[component] = FolderNodeClass(name: component, fullPath: currentPath, orderIndex: i)
                }
                current = current.children[component]!
            }
        }
        return root.children.values.sorted { $0.orderIndex < $1.orderIndex }.map { $0.toStruct(bundle: bundle) }
    }
}

// MARK: - Bookmark Folder Management

struct BookmarkFolderManagementWindow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let langBundle: Bundle

    @State private var draftFolders: [String: String] = [:]
    @State private var snapshotRefreshTick = 0

    private var browsers: [Browser] {
        appState.browserInfos
            .filter { $0.isInstalled && appState.settingsService.syncSettings.bookmarkParticipatingBrowsers.contains($0.browser) }
            .map(\.browser)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "Manage Sync Folders", bundle: langBundle))
                        .font(.title3.bold())
                    Spacer()
                }

                Text(String(localized: "Manage Sync Folders Description", bundle: langBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(browsers, id: \.self) { browser in
                        BookmarkFolderManagementRow(
                            browser: browser,
                            selection: Binding(
                                get: { draftFolders[browser.rawValue] },
                                set: { newValue in
                                    if let newValue, !newValue.isEmpty {
                                        draftFolders[browser.rawValue] = newValue
                                    } else {
                                        draftFolders.removeValue(forKey: browser.rawValue)
                                    }
                                }
                            ),
                            langBundle: langBundle
                        )
                        .environmentObject(appState)
                        Divider()
                    }
                }
                .padding(.vertical, 6)
            }

            HStack {
                Button(String(localized: "Cancel", bundle: langBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(String(localized: "Confirm", bundle: langBundle)) {
                    appState.settingsService.syncSettings.bookmarkSyncFolders = draftFolders.compactMapValues { BookmarkFolderPath.canonicalized($0) }
                    appState.settingsService.syncSettings.bookmarkSyncFolder = nil
                    appState.settingsService.save()
                    appState.broadcastSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 460)
        .onAppear {
            draftFolders = appState.settingsService.syncSettings.bookmarkSyncFolders.compactMapValues { BookmarkFolderPath.canonicalized($0) }
            requestLatestFolderSnapshots()
        }
        .onReceive(appState.backupService.$lastSnapshotUpdate) { _ in
            snapshotRefreshTick += 1
        }
    }

    private func requestLatestFolderSnapshots() {
        let message = WSMessage.pull(site: nil, category: "bookmark_backup")
        for browser in browsers where browser != .safari {
            appState.daemon.broadcast(message, participatingBrowsers: [browser])
        }
    }
}

struct BookmarkFolderManagementRow: View {
    @EnvironmentObject var appState: AppState
    let browser: Browser
    @Binding var selection: String?
    let langBundle: Bundle

    @State private var showingPicker = false

    private var displayName: String {
        BookmarkFolderPath.displayPath(selection, bundle: langBundle) ?? String(localized: "Root Directory (All Bookmarks)", bundle: langBundle)
    }

    private var missing: Bool {
        let canonicalSelection = BookmarkFolderPath.canonicalized(selection)
        if appState.syncService.bookmarkFolderKnownExists(browser, folder: canonicalSelection) {
            return false
        }
        if appState.syncService.missingBookmarkFolders[browser.rawValue] != nil {
            return true
        }
        return appState.syncService.bookmarkFolderMissing(browser, folder: canonicalSelection)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let appURL = appState.browserInfos.first(where: { $0.browser == browser })?.appURL {
                AppIconImage(appURL: appURL)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: browser.sfSymbol)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(browser.displayName)
                    .font(.headline)
                if missing, let selection {
                    Text(String(format: String(localized: "Selected folder not found: %@", bundle: langBundle), BookmarkFolderPath.displayPath(selection, bundle: langBundle) ?? selection))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: missing ? "exclamationmark.triangle.fill" : "folder")
                        .foregroundStyle(missing ? .orange : .primary)
                    Text(displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                FolderSelectionPopover(
                    browser: browser,
                    selectedFolder: $selection,
                    langBundle: langBundle
                )
                .environmentObject(appState)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct FolderSelectionPopover: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let browser: Browser
    @Binding var selectedFolder: String?
    let langBundle: Bundle

    @State private var localSelection: String?
    @State private var nodes: [FolderNode] = []
    @State private var isLoading = false
    @State private var hasSnapshot = true
    @State private var expandedNodes: Set<String> = []
    @State private var showOpenBrowserPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(browser.displayName)
                    .font(.headline)
                Spacer()
                Button {
                    handleRefreshTapped()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh", bundle: langBundle))
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(width: 320, height: 280)
            } else if !hasSnapshot {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Data not retrieved", bundle: langBundle))
                        .font(.headline)
                    Text(String(localized: "Please open this browser and ensure the BrowSync extension is active.", bundle: langBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(format: String(localized: "Open %@", bundle: langBundle), browser.displayName)) {
                        openBrowserAndRequestSnapshot()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
                }
                .padding()
                .frame(width: 320, height: 280)
            } else {
                ScrollViewReader { proxy in
                    List {
                        DisclosureGroup(isExpanded: .constant(true)) {
                            ForEach(nodes) { node in
                                RecursiveFolderPickerNodeView(node: node, localSelection: $localSelection, expandedNodes: $expandedNodes)
                            }
                        } label: {
                            FolderPickerRow(
                                title: String(localized: "Root Directory (All Bookmarks)", bundle: langBundle),
                                isSelected: localSelection == nil
                            ) {
                                localSelection = nil
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: isLoading) { loading in
                        guard !loading, let sel = localSelection else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo(sel, anchor: .center)
                            }
                        }
                    }
                }
                .frame(width: 340, height: 300)
            }

            Divider()
            HStack {
                Button {
                    openBookmarkManager(for: browser, appState: appState)
                } label: {
                    Label(String(localized: "Manage Bookmarks", bundle: langBundle), systemImage: "book")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(String(localized: "Confirm", bundle: langBundle)) {
                    selectedFolder = localSelection
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || !hasSnapshot)
            }
            .padding()
        }
        .onAppear {
            localSelection = selectedFolder
            loadFolders()
            if browser != .safari {
                requestBookmarkSnapshot()
            }
        }
        .onReceive(appState.backupService.$lastSnapshotUpdate) { _ in
            loadFolders()
        }
        .alert(
            String(localized: "Extension Offline", bundle: langBundle),
            isPresented: $showOpenBrowserPrompt
        ) {
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) {}
            Button(String(format: String(localized: "Open %@", bundle: langBundle), browser.displayName)) {
                openBrowserAndRequestSnapshot()
                loadFolders()
            }
        } message: {
            Text(String(format: String(localized: "The BrowSync extension in %@ appears offline. Open %@ now?", bundle: langBundle), browser.displayName, browser.displayName))
        }
    }

    private func handleRefreshTapped() {
        if browser != .safari && !appState.daemon.isConnected(browser: browser) {
            showOpenBrowserPrompt = true
            return
        }
        requestBookmarkSnapshot()
        loadFolders()
    }

    private func openBrowserAndRequestSnapshot() {
        if let appURL = appState.browserInfos.first(where: { $0.browser == browser })?.appURL ?? browser.appURL {
            NSWorkspace.shared.open(appURL)
        }
        requestBookmarkSnapshot()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                requestBookmarkSnapshot()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                requestBookmarkSnapshot()
            }
        }
    }

    private func requestBookmarkSnapshot() {
        guard browser != .safari else {
            loadFolders()
            return
        }
        let msg = WSMessage.pull(site: nil, category: "bookmark_backup")
        appState.daemon.broadcast(msg, participatingBrowsers: [browser])
    }

    private func loadFolders() {
        isLoading = true
        hasSnapshot = true
        Task {
            var rawFolders: [(id: String, parentId: String?, title: String)] = []
            var foundSnapshot = true

            if browser == .safari {
                rawFolders = SafariBookmarkService().readBookmarks().filter(\.isFolder).map { ($0.id, $0.parentId, $0.title) }
            } else if let snapshot = appState.backupService.getSnapshot(sourceBrowser: browser.rawValue) {
                rawFolders = snapshot.filter(\.isFolder).map { ($0.id, $0.parentId, $0.title) }
            } else {
                foundSnapshot = false
            }

            let paths = folderPaths(from: rawFolders, browser: browser)
            let loadedNodes = BookmarkSyncTabView.buildTree(from: paths, bundle: langBundle)

            await MainActor.run {
                nodes = loadedNodes
                expandedNodes = Set(paths.flatMap { path in
                    var result: [String] = []
                    var current = ""
                    for component in path.components(separatedBy: "/") where !component.isEmpty {
                        current = current.isEmpty ? component : current + "/" + component
                        result.append(current)
                    }
                    return result
                })
                hasSnapshot = foundSnapshot
                isLoading = false
            }
        }
    }

    private func folderPaths(from rawFolders: [(id: String, parentId: String?, title: String)], browser: Browser) -> [String] {
        var idToFolder: [String: (id: String, parentId: String?, title: String)] = [:]
        for folder in rawFolders { idToFolder[folder.id] = folder }

        func pathComponent(for folder: (id: String, parentId: String?, title: String)) -> String {
            switch folder.id {
            case "1", BookmarkFolderPath.rootBar, BookmarkFolderPath.rootFavorites:
                return BookmarkFolderPath.rootBar
            case "2", BookmarkFolderPath.rootOther:
                return BookmarkFolderPath.rootOther
            case "3", BookmarkFolderPath.rootMobile:
                return BookmarkFolderPath.rootMobile
            case "firefox-toolbar-root":
                return BookmarkFolderPath.rootBar
            case "firefox-menu-root":
                return BookmarkFolderPath.rootMenu
            case "firefox-other-root":
                return BookmarkFolderPath.rootOther
            case "firefox-mobile-root":
                return BookmarkFolderPath.rootMobile
            default:
                return folder.title
            }
        }

        return rawFolders.compactMap { folder in
            if ["0", "1", "2", "3"].contains(folder.id) { return nil }
            var path = pathComponent(for: folder)
            var currentId = folder.parentId
            while let parentId = currentId, parentId != "0" {
                if let parent = idToFolder[parentId], !["0", "1", "2", "3"].contains(parent.id) {
                    path = pathComponent(for: parent) + "/" + path
                    currentId = parent.parentId
                } else {
                    if browser != .safari {
                        if parentId == "1" { path = BookmarkFolderPath.rootBar + "/" + path }
                        else if parentId == "2" { path = BookmarkFolderPath.rootOther + "/" + path }
                        else if parentId == "3" { path = BookmarkFolderPath.rootMobile + "/" + path }
                    } else if parentId == "1" {
                        path = BookmarkFolderPath.rootFavorites + "/" + path
                    }
                    break
                }
            }
            return path
        }
    }
}

struct RecursiveFolderPickerNodeView: View {
    let node: FolderNode
    @Binding var localSelection: String?
    @Binding var expandedNodes: Set<String>

    var body: some View {
        let label = FolderPickerRow(title: node.name, isSelected: localSelection == node.id) {
            localSelection = node.id
        }

        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedNodes.contains(node.id) },
                set: { isExpanded in
                    if isExpanded {
                        expandedNodes.insert(node.id)
                    } else {
                        expandedNodes.remove(node.id)
                    }
                }
            )) {
                ForEach(children) { child in
                    RecursiveFolderPickerNodeView(node: child, localSelection: $localSelection, expandedNodes: $expandedNodes)
                }
            } label: {
                label
            }
            .id(node.id)
        } else {
            label
                .id(node.id)
        }
    }
}

struct FolderPickerRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(isSelected ? .white : .primary)
            .background(isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folder Selection Sheet

struct FolderSelectionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedFolder: String?
    @Binding var sourceBrowser: Browser
    let langBundle: Bundle
    
    @Environment(\.dismiss) var dismiss
    @State private var localSelection: String? = nil
    
    @State private var localSelectionBrowser: Browser?
    @State private var selectedBrowser: Browser = .safari
    @State private var nodes: [FolderNode] = []
    @State private var isLoading = false
    @State private var hasSnapshot = true
    @State private var expandedNodes: Set<String> = []
    @State private var showOpenBrowserPrompt = false
    
    var isTwoWay: Bool {
        appState.settingsService.syncSettings.bookmarkSyncStrategy == .twoWayMerge
    }
    
    var displayBrowsers: [Browser] {
        Browser.allCases.filter { browser in
            appState.settingsService.syncSettings.bookmarkParticipatingBrowsers.contains(browser) &&
            appState.browserInfos.contains { $0.browser == browser && $0.isInstalled }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Select Folder", bundle: langBundle))
                    .font(.headline)
                
                Spacer()
                
                Button {
                    handleRefreshTapped()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh", bundle: langBundle))
            }
            .padding()
            
            Divider()
            
            if isTwoWay {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(displayBrowsers, id: \.self) { browser in
                            let isSelected = selectedBrowser == browser
                            Button {
                                selectedBrowser = browser
                                loadFolders()
                            } label: {
                                HStack(spacing: 6) {
                                    if let appURL = appState.browserInfos.first(where: { $0.browser == browser })?.appURL {
                                        AppIconImage(appURL: appURL)
                                            .frame(width: 16, height: 16)
                                    }
                                    Text(browser.displayName)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                                .foregroundColor(isSelected ? .white : .primary)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isSelected ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                Divider()
            }
            
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if !hasSnapshot {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Data not retrieved", bundle: langBundle))
                        .font(.headline)
                    Text(String(localized: "Please open this browser and ensure the BrowSync extension is active.", bundle: langBundle))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(String(format: String(localized: "Open %@", bundle: langBundle), selectedBrowser.displayName)) {
                        openBrowserAndRequestSnapshot()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .padding()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        DisclosureGroup(isExpanded: .constant(true)) {
                            ForEach(nodes) { node in
                                RecursiveFolderNodeView(
                                    node: node,
                                    localSelection: $localSelection,
                                    localSelectionBrowser: $localSelectionBrowser,
                                    selectedBrowser: selectedBrowser,
                                    expandedNodes: $expandedNodes
                                )
                            }
                        } label: {
                            Button {
                                localSelection = nil
                                localSelectionBrowser = selectedBrowser
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(String(localized: "Root Directory (All Bookmarks)", bundle: langBundle))
                                    Spacer()
                                    if localSelection == nil && localSelectionBrowser == selectedBrowser {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(localSelection == nil && localSelectionBrowser == selectedBrowser ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: isLoading) { loading in
                        if !loading, let sel = localSelection {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation {
                                    proxy.scrollTo(sel, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Button {
                    openBookmarkManager(for: selectedBrowser, appState: appState)
                } label: {
                    Image(systemName: "book")
                    Text(String(localized: "Manage Bookmarks", bundle: langBundle))
                }
                .disabled(isLoading || !hasSnapshot)
                
                Spacer()
                
                Button(String(localized: "Cancel", bundle: langBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button(String(localized: "Select", bundle: langBundle)) {
                    selectedFolder = localSelection
                    if let browser = localSelectionBrowser {
                        sourceBrowser = browser
                    } else {
                        sourceBrowser = selectedBrowser
                    }
                    appState.settingsService.save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || !hasSnapshot)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
        .onAppear {
            localSelection = selectedFolder
            let source = appState.settingsService.syncSettings.bookmarkSourceBrowser
            localSelectionBrowser = source
            if isTwoWay {
                if displayBrowsers.contains(source) {
                    selectedBrowser = source
                } else {
                    selectedBrowser = displayBrowsers.first ?? .safari
                }
            } else {
                selectedBrowser = source
            }
            loadFolders()
            if selectedBrowser != .safari {
                requestBookmarkSnapshot()
            }
        }
        .onReceive(appState.backupService.$lastSnapshotUpdate) { _ in
            loadFolders()
        }
        .alert(
            String(localized: "Extension Offline", bundle: langBundle),
            isPresented: $showOpenBrowserPrompt
        ) {
            Button(String(localized: "Cancel", bundle: langBundle), role: .cancel) {}
            Button(String(format: String(localized: "Open %@", bundle: langBundle), selectedBrowser.displayName)) {
                openBrowserAndRequestSnapshot()
                loadFolders()
            }
        } message: {
            Text(String(format: String(localized: "The BrowSync extension in %@ appears offline. Open %@ now?", bundle: langBundle), selectedBrowser.displayName, selectedBrowser.displayName))
        }
    }

    private func handleRefreshTapped() {
        if selectedBrowser != .safari && !appState.daemon.isConnected(browser: selectedBrowser) {
            showOpenBrowserPrompt = true
            return
        }
        let msg = WSMessage.pull(site: nil, category: "bookmark_backup")
        appState.daemon.broadcast(msg, participatingBrowsers: [selectedBrowser])
        loadFolders()
    }
    
    private func openBrowserAndRequestSnapshot() {
        if let appURL = appState.browserInfos.first(where: { $0.browser == selectedBrowser })?.appURL ?? selectedBrowser.appURL {
            NSWorkspace.shared.open(appURL)
        }
        requestBookmarkSnapshot()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                requestBookmarkSnapshot()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                requestBookmarkSnapshot()
            }
        }
    }

    private func requestBookmarkSnapshot() {
        guard selectedBrowser != .safari else {
            loadFolders()
            return
        }
        let msg = WSMessage.pull(site: nil, category: "bookmark_backup")
        appState.daemon.broadcast(msg, participatingBrowsers: [selectedBrowser])
    }

    private func loadFolders() {
        isLoading = true
        hasSnapshot = true
        
        let browserToLoad = selectedBrowser
        
        Task {
            var rawFolders: [(id: String, parentId: String?, title: String)] = []
            var foundSnapshot = true
            
            if browserToLoad == .safari {
                let bookmarks = SafariBookmarkService().readBookmarks()
                rawFolders = bookmarks.filter { $0.isFolder }.map { ($0.id, $0.parentId, $0.title) }
            } else {
                if let snapshot = appState.backupService.getSnapshot(sourceBrowser: browserToLoad.rawValue) {
                    rawFolders = snapshot.filter { $0.isFolder }.map { ($0.id, $0.parentId, $0.title) }
                } else {
                    foundSnapshot = false
                }
            }

            var idToFolder: [String: (id: String, parentId: String?, title: String)] = [:]
            for f in rawFolders { idToFolder[f.id] = f }

            func pathComponent(for folder: (id: String, parentId: String?, title: String)) -> String {
                switch folder.id {
                case "1", BookmarkFolderPath.rootBar, BookmarkFolderPath.rootFavorites:
                    return BookmarkFolderPath.rootBar
                case "2", BookmarkFolderPath.rootOther:
                    return BookmarkFolderPath.rootOther
                case "3", BookmarkFolderPath.rootMobile:
                    return BookmarkFolderPath.rootMobile
                case "firefox-toolbar-root":
                    return BookmarkFolderPath.rootBar
                case "firefox-menu-root":
                    return BookmarkFolderPath.rootMenu
                case "firefox-other-root":
                    return BookmarkFolderPath.rootOther
                case "firefox-mobile-root":
                    return BookmarkFolderPath.rootMobile
                default:
                    return folder.title
                }
            }
            
            if browserToLoad == .safari {
                let hasChildren = rawFolders.contains(where: { $0.parentId == "2" })
                if !hasChildren {
                    rawFolders.removeAll(where: { $0.id == "2" })
                    idToFolder.removeValue(forKey: "2")
                }
            }

            var paths: [String] = []
            
            for f in rawFolders {
                var path = pathComponent(for: f)
                var currentId = f.parentId
                while let pid = currentId {
                    if pid == "0" { break }
                    
                    if let parent = idToFolder[pid] {
                        path = pathComponent(for: parent) + "/" + path
                        currentId = parent.parentId
                    } else {
                        if browserToLoad == .safari {
                            if pid == "1" {
                                path = BookmarkFolderPath.rootFavorites + "/" + path
                            }
                            // If pid == "2" for Safari, it's the root Bookmarks Menu, so we prepend nothing.
                        } else {
                            if pid == "1" { path = BookmarkFolderPath.rootBar + "/" + path }
                            else if pid == "2" { path = BookmarkFolderPath.rootOther + "/" + path }
                            else if pid == "3" { path = BookmarkFolderPath.rootMobile + "/" + path }
                        }
                        break
                    }
                }
                paths.append(path)
            }

            let loadedNodes = BookmarkSyncTabView.buildTree(from: paths, bundle: langBundle)
            
            await MainActor.run {
                self.nodes = loadedNodes
                self.hasSnapshot = foundSnapshot
                self.isLoading = false
                
                // Auto-expand paths containing the selected folder
                if let selection = self.localSelection {
                    let components = selection.components(separatedBy: "/")
                    var currentPath = ""
                    for component in components {
                        if !component.isEmpty {
                            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
                            self.expandedNodes.insert(currentPath)
                        }
                    }
                }
            }
        }
    }
}

struct RecursiveFolderNodeView: View {
    let node: FolderNode
    @Binding var localSelection: String?
    @Binding var localSelectionBrowser: Browser?
    let selectedBrowser: Browser
    @Binding var expandedNodes: Set<String>
    
    var body: some View {
        let isSelected = localSelection == node.id && localSelectionBrowser == selectedBrowser
        
        let label = Button {
            localSelection = node.id
            localSelectionBrowser = selectedBrowser
        } label: {
            HStack {
                Image(systemName: "folder")
                Text(node.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedNodes.contains(node.id) },
                    set: { isExpanded in
                        if isExpanded { expandedNodes.insert(node.id) }
                        else { expandedNodes.remove(node.id) }
                    }
                )
            ) {
                ForEach(children) { child in
                    RecursiveFolderNodeView(
                        node: child,
                        localSelection: $localSelection,
                        localSelectionBrowser: $localSelectionBrowser,
                        selectedBrowser: selectedBrowser,
                        expandedNodes: $expandedNodes
                    )
                }
            } label: {
                label
            }
            .id(node.id)
        } else {
            label
                .id(node.id)
        }
    }
}
