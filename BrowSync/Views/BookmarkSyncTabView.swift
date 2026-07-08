// BookmarkSyncTabView.swift
// BrowSync — Bookmark Sync Tab

import SwiftUI

struct BookmarkSyncTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupService: BackupService
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var isSyncing = false
    @State private var showSuccess = false
    @State private var itemToDelete: DeletedBookmark?
    @State private var showingDeleteConfirmation = false
    @State private var showingClearAllConfirmation = false
    @State private var showingRestoreAllConfirmation = false
    @State private var showUpgradeAlert = false
    @State private var showSandboxAlert = false
    @State private var showAutoSyncUpgradeAlert = false
    
    @State private var showFolderSheet = false
    
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
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Bookmark Backup Warning Header", bundle: langBundle.bundle), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        
                        Group {
                            Text(String(localized: "Bookmark Backup Warning Detail", bundle: langBundle.bundle))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(String(localized: "Participating Browsers", bundle: langBundle.bundle)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(availableBrowsers) { info in
                                Toggle(isOn: Binding(
                                    get: { syncSettings.bookmarkParticipatingBrowsers.wrappedValue.contains(info.browser) },
                                    set: { isParticipating in
                                        if isParticipating {
                                            guard appState.purchaseService.isProUnlocked ||
                                                    syncSettings.wrappedValue.bookmarkParticipatingBrowsers.count < ProLimits.freeSyncBrowserCount else {
                                                showUpgradeAlert = true
                                                return
                                            }
                                            syncSettings.wrappedValue.bookmarkParticipatingBrowsers.insert(info.browser)
                                        } else {
                                            syncSettings.wrappedValue.bookmarkParticipatingBrowsers.remove(info.browser)
                                        }
                                        appState.settingsService.save()
                                        appState.broadcastSettings()
                                    }
                                )) {
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
                                        if !appState.purchaseService.isProUnlocked &&
                                            !syncSettings.bookmarkParticipatingBrowsers.wrappedValue.contains(info.browser) &&
                                            syncSettings.bookmarkParticipatingBrowsers.wrappedValue.count >= ProLimits.freeSyncBrowserCount {
                                            ProBadge()
                                        }
                                        if info.browser == .safari {
#if APP_STORE
                                            if !sandboxManager.hasSafariAccess {
                                                Button(String(localized: "Grant Access", bundle: langBundle.bundle)) {
                                                    sandboxManager.requestSafariAccess { granted in
                                                        if granted {
                                                            // Auto-enable Safari if granted successfully
                                                            syncSettings.wrappedValue.bookmarkParticipatingBrowsers.insert(.safari)
                                                            appState.settingsService.save()
                                                            appState.broadcastSettings()
                                                        }
                                                    }
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                            }
#endif
                                        }
                                    }
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

                Section(String(localized: "Sync Strategy", bundle: langBundle.bundle)) {
                    Picker(String(localized: "Bookmark Strategy", bundle: langBundle.bundle), selection: syncSettings.bookmarkSyncStrategy) {
                        ForEach(BookmarkSyncStrategy.allCases) { strategy in
                            Text(String(localized: String.LocalizationValue(strategy.displayName), bundle: langBundle.bundle)).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if syncSettings.bookmarkSyncStrategy.wrappedValue == .twoWayMerge {
                        Text(String(localized: "Merge Warning Note", bundle: langBundle.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                
                    if syncSettings.bookmarkSyncStrategy.wrappedValue == .oneWay {
                        Picker(String(localized: "Bookmark Source Browser", bundle: langBundle.bundle), selection: syncSettings.bookmarkSourceBrowser) {
                            ForEach(availableBrowsers) { info in
                                Label {
                                    Text(info.displayName)
                                } icon: {
                                    AppIconImage(appURL: info.appURL)
                                }
                                .tag(info.browser)
                            }
                        }
                        .pickerStyle(.menu)
                        
#if !APP_STORE
                        if syncSettings.bookmarkSourceBrowser.wrappedValue == .safari && !appState.hasFullDiskAccess {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundStyle(.red)
                                    Text(String(localized: "Cannot read Safari bookmarks", bundle: langBundle.bundle))
                                        .font(.headline)
                                        .foregroundStyle(.red)
                                }
                                
                                Text(String(localized: "Safari privacy warning", bundle: langBundle.bundle))
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
                                
                                Text(String(localized: "Note restart", bundle: langBundle.bundle))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.vertical, 4)
                        }
#endif
                    }
                    
                    HStack {
                        Text(String(localized: "Sync Folder", bundle: langBundle.bundle))
                        Spacer()
                        Button {
                            showFolderSheet = true
                        } label: {
                                HStack(spacing: 6) {
                                    if let appURL = appState.browserInfos.first(where: { $0.browser == syncSettings.bookmarkSourceBrowser.wrappedValue })?.appURL {
                                        AppIconImage(appURL: appURL)
                                            .frame(width: 16, height: 16)
                                    }
                                    Text(syncSettings.bookmarkSyncFolder.wrappedValue ?? String(localized: "Root Directory (All Bookmarks)", bundle: langBundle.bundle))
                                        .truncationMode(.middle)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                            .popover(isPresented: $showFolderSheet, arrowEdge: .bottom) {
                                FolderSelectionSheet(
                                    selectedFolder: syncSettings.bookmarkSyncFolder,
                                    sourceBrowser: syncSettings.bookmarkSourceBrowser,
                                    langBundle: langBundle.bundle
                                )
                                .environmentObject(appState)
                            }
                        }
                    .onChange(of: syncSettings.bookmarkSyncStrategy.wrappedValue) { _ in
                        appState.settingsService.save()
                    }
                    .onChange(of: syncSettings.bookmarkSourceBrowser.wrappedValue) { _ in
                        appState.settingsService.save()
                    }
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
#if !APP_STORE
                if (syncSettings.bookmarkSyncStrategy.wrappedValue == .twoWayMerge || 
                   (syncSettings.bookmarkSyncStrategy.wrappedValue == .oneWay && syncSettings.bookmarkSourceBrowser.wrappedValue == .safari)) 
                   && !appState.hasFullDiskAccess {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.red)
                                Text(String(localized: "Cannot read Safari bookmarks", bundle: langBundle.bundle))
                                    .font(.headline)
                                    .foregroundStyle(.red)
                            }
                            
                            Text(String(localized: "Safari privacy warning 2", bundle: langBundle.bundle))
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
                        }
                        .padding(.vertical, 4)
                    }
                }
#endif
                
                Section(String(localized: "Deleted Bookmarks (Trash Bin)", bundle: langBundle.bundle)) {
                    if backupService.deletedBookmarks.isEmpty {
                        Text(String(localized: "No deleted bookmarks", bundle: langBundle.bundle))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(String(localized: "These bookmarks were deleted recently. You can restore them individually.", bundle: langBundle.bundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Restore All", bundle: langBundle.bundle)) {
                                showingRestoreAllConfirmation = true
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                            
                            Button(String(localized: "Clear All", bundle: langBundle.bundle)) {
                                showingClearAllConfirmation = true
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .font(.caption)
                        }
                        
                        ForEach(backupService.deletedBookmarks) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                        .font(.headline)
                                    HStack(spacing: 4) {
                                        Text(item.isFolder ? "Folder" : (item.url ?? "Unknown URL"))
                                        Text("•")
                                        Text(item.deletedAt.formatted(date: .numeric, time: .shortened))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Button(String(localized: "Restore", bundle: langBundle.bundle)) {
                                    restoreBookmark(item)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                                
                                Button(action: {
                                    itemToDelete = item
                                    showingDeleteConfirmation = true
                                }) {
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
            .formStyle(.grouped)
            .disabled(!syncSettings.enabledCategories.wrappedValue.contains(.bookmarks))
            .alert(
                String(localized: "Confirm deletion", bundle: langBundle.bundle),
                isPresented: $showingDeleteConfirmation,
                presenting: itemToDelete
            ) { item in
                Button(String(localized: "Delete Permanently", bundle: langBundle.bundle), role: .destructive) {
                    backupService.removeDeletedBookmark(id: item.id)
                }
                Button(String(localized: "Cancel", bundle: langBundle.bundle), role: .cancel) {}
            } message: { item in
                Text(String(localized: "This deleted bookmark will be permanently removed from the trash bin.", bundle: langBundle.bundle))
            }
            .alert(
                String(localized: "Confirm Clear All", bundle: langBundle.bundle),
                isPresented: $showingClearAllConfirmation
            ) {
                Button(String(localized: "Clear All", bundle: langBundle.bundle), role: .destructive) {
                    backupService.clearAllDeletedBookmarks()
                }
                Button(String(localized: "Cancel", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(localized: "Are you sure you want to permanently delete all bookmarks in the trash bin?", bundle: langBundle.bundle))
            }
            .alert(
                String(localized: "Confirm Restore All", bundle: langBundle.bundle),
                isPresented: $showingRestoreAllConfirmation
            ) {
                Button(String(localized: "Restore All", bundle: langBundle.bundle)) {
                    restoreAllBookmarks()
                }
                Button(String(localized: "Cancel", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(localized: "Are you sure you want to restore all bookmarks from the trash bin?", bundle: langBundle.bundle))
            }
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
        
        // Restore locally
        appState.syncService.recordInternalWrite()
        safariSvc.applyBookmarks(currentSafariBookmarks, from: "RestoreAll", isFullMirror: false)
        
        // Broadcast to other browsers
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
        
        // Clear trash
        backupService.clearAllDeletedBookmarks()
        
        showSuccess = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSuccess = false
        }
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
        
        // Restore locally
        appState.syncService.recordInternalWrite()
        safariSvc.applyBookmarks(currentSafariBookmarks, from: "Restore", isFullMirror: false)
        
        // Broadcast to other browsers
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
        
        // Remove from trash
        backupService.removeDeletedBookmark(id: item.id)
        
        showSuccess = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSuccess = false
        }
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
    
    func toStruct() -> FolderNode {
        let sortedChildren = children.values.sorted { $0.orderIndex < $1.orderIndex }.map { $0.toStruct() }
        return FolderNode(id: fullPath, name: name, children: sortedChildren.isEmpty ? nil : sortedChildren)
    }
}

extension BookmarkSyncTabView {
    static func buildTree(from paths: [String]) -> [FolderNode] {
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
        return root.children.values.sorted { $0.orderIndex < $1.orderIndex }.map { $0.toStruct() }
    }
}

// MARK: - Folder Selection Sheet

// MARK: - Folder Selection Sheet

struct FolderSelectionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedFolder: String?
    @Binding var sourceBrowser: Browser
    let langBundle: Bundle
    
    @Environment(\.dismiss) var dismiss
    @State private var localSelection: String? = nil
    @State private var showingAddFolder = false
    @State private var newFolderName = ""
    
    @State private var localSelectionBrowser: Browser?
    @State private var selectedBrowser: Browser = .safari
    @State private var nodes: [FolderNode] = []
    @State private var isLoading = false
    @State private var hasSnapshot = true
    @State private var expandedNodes: Set<String> = []
    
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
                    let msg = WSMessage.pull(site: nil, category: "bookmark_backup")
                    appState.daemon.broadcast(msg, participatingBrowsers: [selectedBrowser])
                    loadFolders()
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
                    
                    if let url = selectedBrowser.appURL {
                        Button(String(format: String(localized: "Open %@", bundle: langBundle), selectedBrowser.displayName)) {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    }
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
                    showingAddFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                    Text(String(localized: "Add Folder", bundle: langBundle))
                }
                .disabled(isLoading || !hasSnapshot)
                .popover(isPresented: $showingAddFolder) {
                    VStack(spacing: 12) {
                        Text(String(localized: "New Folder Name", bundle: langBundle))
                            .font(.headline)
                        TextField("", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        HStack {
                            Button(String(localized: "Cancel", bundle: langBundle)) {
                                showingAddFolder = false
                                newFolderName = ""
                            }
                            Button(String(localized: "Add", bundle: langBundle)) {
                                if !newFolderName.isEmpty {
                                    let newPath = localSelection == nil ? newFolderName : localSelection! + "/" + newFolderName
                                    if selectedBrowser == .safari {
                                        SafariBookmarkService().ensureFolderExists(path: newPath)
                                    }
                                    localSelection = newPath
                                    localSelectionBrowser = selectedBrowser
                                    loadFolders()
                                }
                                showingAddFolder = false
                                newFolderName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newFolderName.isEmpty)
                        }
                    }
                    .padding()
                }
                
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
        }
        .onReceive(appState.backupService.$lastSnapshotUpdate) { _ in
            loadFolders()
        }
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
            
            if browserToLoad == .safari {
                let hasChildren = rawFolders.contains(where: { $0.parentId == "2" })
                if !hasChildren {
                    rawFolders.removeAll(where: { $0.id == "2" })
                    idToFolder.removeValue(forKey: "2")
                }
            }

            var paths: [String] = []
            
            for f in rawFolders {
                var path = f.title
                var currentId = f.parentId
                while let pid = currentId {
                    if pid == "0" { break }
                    
                    if let parent = idToFolder[pid] {
                        path = parent.title + "/" + path
                        currentId = parent.parentId
                    } else {
                        if browserToLoad == .safari {
                            if pid == "1" {
                                path = String(localized: "Favorites", bundle: langBundle) + "/" + path
                            }
                            // If pid == "2" for Safari, it's the root Bookmarks Menu, so we prepend nothing.
                        } else {
                            if pid == "1" { path = String(localized: "Bookmarks Bar", bundle: langBundle) + "/" + path }
                            else if pid == "2" { path = String(localized: "Other Bookmarks", bundle: langBundle) + "/" + path }
                            else if pid == "3" { path = String(localized: "Mobile Bookmarks", bundle: langBundle) + "/" + path }
                        }
                        break
                    }
                }
                paths.append(path)
            }

            let loadedNodes = BookmarkSyncTabView.buildTree(from: paths)
            
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
