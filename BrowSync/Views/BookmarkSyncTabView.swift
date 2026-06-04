// BookmarkSyncTabView.swift
// BrowSync — Bookmark Sync Tab

import SwiftUI

struct BookmarkSyncTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupService: BackupService
    @State private var isSyncing = false
    @State private var showSuccess = false
    @State private var backupToDelete: BookmarkBackup?
    @State private var showingDeleteConfirmation = false
    
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
                Text("书签同步")
                    .font(.title2.bold())
                
                Spacer()
                
                Toggle("开启书签同步", isOn: Binding(
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
                            Text("同步中...")
                        }
                    } else if showSuccess {
                        Label("同步完成", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(showSuccess ? .green : .accentColor)
                .disabled(isSyncing || appState.syncService.isSyncing || showSuccess)
            }
            .padding()

            Form {
                Section("参与同步的浏览器") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Toggle(isOn: Binding(
                                    get: { syncSettings.bookmarkParticipatingBrowsers.wrappedValue.contains(info.browser) },
                                    set: { isParticipating in
                                        if isParticipating {
                                            syncSettings.wrappedValue.bookmarkParticipatingBrowsers.insert(info.browser)
                                        } else {
                                            syncSettings.wrappedValue.bookmarkParticipatingBrowsers.remove(info.browser)
                                        }
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
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }

                Section("同步策略选择") {
                    Picker("默认策略", selection: syncSettings.bookmarkSyncStrategy) {
                        ForEach(BookmarkSyncStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                
                    if syncSettings.bookmarkSyncStrategy.wrappedValue == .oneWay {
                        Picker("数据源浏览器", selection: syncSettings.bookmarkSourceBrowser) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Text(info.displayName).tag(info.browser)
                            }
                        }
                        .pickerStyle(.menu)
                        
                        
                        if syncSettings.bookmarkSourceBrowser.wrappedValue == .safari && !appState.hasFullDiskAccess {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundStyle(.red)
                                    Text("无法读取 Safari 书签")
                                        .font(.headline)
                                        .foregroundStyle(.red)
                                }
                                
                                Text("由于 macOS 的隐私机制，将 Safari 作为同步源需要授予应用“完全磁盘访问权限”。否则 BrowSync 无法读取您的 Safari 书签。")
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                HStack {
                                    Button("去系统设置授权") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    
                                    Button("已授权，刷新状态") {
                                        appState.checkFullDiskAccess()
                                    }
                                    .buttonStyle(.link)
                                    .controlSize(.small)
                                }
                                
                                Text("注：授权后可能需要完全退出并重新打开 BrowSync 才能生效。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.vertical, 4)
                        }
                    }
                    
                    Toggle("自动同步书签", isOn: syncSettings.bookmarkAutoSync)
                }
                if (syncSettings.bookmarkSyncStrategy.wrappedValue == .twoWayMerge || 
                   (syncSettings.bookmarkSyncStrategy.wrappedValue == .oneWay && syncSettings.bookmarkSourceBrowser.wrappedValue == .safari)) 
                   && !appState.hasFullDiskAccess {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.red)
                                Text("无法读取 Safari 书签")
                                    .font(.headline)
                                    .foregroundStyle(.red)
                            }
                            
                            Text("由于 macOS 的隐私机制，读取 Safari 书签需要授予应用“完全磁盘访问权限”。请前往系统设置进行授权。")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            HStack {
                                Button("去系统设置授权") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button("已授权，刷新状态") {
                                    appState.checkFullDiskAccess()
                                }
                                .buttonStyle(.link)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section("同步历史与备份") {
                    if backupService.backups.isEmpty {
                        Text("暂无备份记录")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("系统会自动保留最近 20 个备份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        ForEach(backupService.backups) { backup in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(backup.timestamp.formatted(date: .numeric, time: .shortened))
                                        .font(.headline)
                                    Text("来源: \(backup.sourceBrowser) (\(backup.itemCount) 项)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Button("恢复此版本") {
                                    restoreBackup(backup)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                                
                                Button(action: {
                                    backupToDelete = backup
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
                "确定要删除此备份吗？",
                isPresented: $showingDeleteConfirmation,
                presenting: backupToDelete
            ) { backup in
                Button("删除", role: .destructive) {
                    backupService.deleteBackup(id: backup.id)
                }
                Button("取消", role: .cancel) {}
            } message: { backup in
                Text("删除后将无法恢复。")
            }
        }
    }
    
    private func restoreBackup(_ backup: BookmarkBackup) {
        guard let bookmarks = backupService.getBookmarks(for: backup.id) else { return }
        
        if backup.sourceBrowser == "safari" {
            // Apply only to Safari natively
            let syncBookmarks = bookmarks.compactMap { b -> SyncBookmark? in
                let urlStr: String?
                if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                if !b.isFolder && urlStr == nil { return nil }
                return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar ?? false)
            }
            let safariSvc = SafariBookmarkService()
            safariSvc.applyBookmarks(syncBookmarks, from: backup.sourceBrowser, isFullMirror: true)
        } else {
            // Send back to the specific Chromium extension it came from
            let pushMsg = WSMessage(
                type: .sync,
                site: "*",
                category: "bookmarks",
                payload: .bookmarks(bookmarks),
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970,
                isFullMirror: true // Force overwrite
            )
            
            let clientId = backup.sourceBrowser.replacingOccurrences(of: "_before_sync", with: "")
            appState.daemon.send(pushMsg, toClientId: clientId)
        }
        
        showSuccess = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSuccess = false
        }
    }
}
