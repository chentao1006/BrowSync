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
                Section(String(localized: "Participating Browsers", bundle: langBundle.bundle)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
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
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
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
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
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
                    
                    Toggle(isOn: Binding(
                        get: { appState.purchaseService.isProUnlocked && syncSettings.bookmarkAutoSync.wrappedValue },
                        set: { enabled in
                            guard appState.purchaseService.isProUnlocked else {
                                showUpgradeAlert = true
                                syncSettings.bookmarkAutoSync.wrappedValue = false
                                return
                            }
                            syncSettings.bookmarkAutoSync.wrappedValue = enabled
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(String(localized: "Real-time Auto Sync", bundle: langBundle.bundle))
                            ProBadge()
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
