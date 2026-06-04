// StateSyncTabView.swift
// BrowSync — State Sync Tab

import SwiftUI

struct StateSyncTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSyncing = false
    @State private var showSuccess = false
    @State private var siteToDelete: WebsiteSyncSetting?
    
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
                Text("状态同步")
                    .font(.title2.bold())
                
                Spacer()
                
                Toggle("开启状态同步", isOn: Binding(
                    get: { syncSettings.enabledCategories.wrappedValue.contains(.browserData) },
                    set: { enabled in
                        if enabled {
                            syncSettings.wrappedValue.enabledCategories.insert(.browserData)
                        } else {
                            syncSettings.wrappedValue.enabledCategories.remove(.browserData)
                        }
                    }
                ))
                .toggleStyle(.switch)
                
                Button {
                    Task {
                        isSyncing = true
                        await appState.sync(categories: [.browserState, .browserData, .localStorage, .history])
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
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("部分网站可能无法成功同步状态", systemImage: "info.circle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Group {
                            Text("原因：").fontWeight(.bold) +
                            Text("许多网站使用浏览器指纹或与设备绑定的安全 Token 进行验证。由于浏览器安全限制，扩展无法提取这些数据，且这些 Token 在不同浏览器环境可能被判定为无效。")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                            
                        Group {
                            Text("方案：").fontWeight(.bold) +
                            Text("对于无法通过同步保持登录的网站，建议您在各浏览器中分别手动登录，或将该网站加入下方列表并关闭其状态同步。")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("参与同步的浏览器") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Toggle(isOn: Binding(
                                    get: { syncSettings.stateParticipatingBrowsers.wrappedValue.contains(info.browser) },
                                    set: { isParticipating in
                                        if isParticipating {
                                            syncSettings.wrappedValue.stateParticipatingBrowsers.insert(info.browser)
                                        } else {
                                            syncSettings.wrappedValue.stateParticipatingBrowsers.remove(info.browser)
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
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }

                Section("网站选项") {
                    Picker("默认策略", selection: syncSettings.browserDataSyncStrategy) {
                        ForEach(BrowserDataSyncStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if syncSettings.browserDataSyncStrategy.wrappedValue == .primaryWins {
                        Picker("数据源浏览器", selection: syncSettings.stateSourceBrowser) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Text(info.displayName).tag(info.browser)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Picker("名单模式", selection: syncSettings.websiteListPolicy) {
                        ForEach(WebsiteListPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Toggle("实时自动同步", isOn: syncSettings.automaticSync)
                        .padding(.vertical, 4)
                    
                    HStack {
                        Text("网站列表")
                            .font(.headline)
                        Spacer()
                        Button {
                            syncSettings.websiteSettings.wrappedValue.append(WebsiteSyncSetting(domain: "", strategy: nil))
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    .padding(.top, 4)
                    
                    ForEach(syncSettings.websiteSettings) { $site in
                        HStack {
                            TextField("", text: $site.domain, prompt: Text("域名 (如: apple.com)"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            
                            Picker("", selection: $site.strategy) {
                                Text("默认策略").tag(BrowserDataSyncStrategy?.none)
                                ForEach(BrowserDataSyncStrategy.allCases) { s in
                                    Text(s.displayName).tag(BrowserDataSyncStrategy?.some(s))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: $site.strategy.wrappedValue) { _, newValue in
                                if newValue == .primaryWins && syncSettings.browserDataSyncStrategy.wrappedValue != .primaryWins {
                                    if $site.sourceBrowser.wrappedValue == nil {
                                        let firstInstalled = appState.browserInfos.first(where: { $0.isInstalled })?.browser ?? .safari
                                        $site.sourceBrowser.wrappedValue = firstInstalled
                                    }
                                }
                            }
                            
                            if ($site.strategy.wrappedValue ?? syncSettings.browserDataSyncStrategy.wrappedValue) == .primaryWins {
                                Picker("", selection: $site.sourceBrowser) {
                                    if syncSettings.browserDataSyncStrategy.wrappedValue == .primaryWins {
                                        Text("默认源").tag(Browser?.none)
                                    }
                                    ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                        Text(info.displayName).tag(Browser?.some(info.browser))
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: 120)
                            }

                            Button(role: .destructive) {
                                siteToDelete = $site.wrappedValue
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!syncSettings.enabledCategories.wrappedValue.contains(.browserData))
            .alert("确定要删除此规则吗？", isPresented: Binding(
                get: { siteToDelete != nil },
                set: { if !$0 { siteToDelete = nil } }
            ), presenting: siteToDelete) { site in
                Button("删除", role: .destructive) {
                    syncSettings.websiteSettings.wrappedValue.removeAll(where: { $0.id == site.id })
                }
                Button("取消", role: .cancel) {}
            } message: { site in
                Text("删除网站 \"\(site.domain)\" 的独立规则后将恢复使用全局策略。")
            }
        }
    }
}
