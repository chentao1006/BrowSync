// StateSyncTabView.swift
// BrowSync — State Sync Tab

import SwiftUI

struct StateSyncTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var isSyncing = false
    @State private var showSuccess = false
    @State private var siteToDelete: WebsiteSyncSetting?
    @State private var showDisabledDomainAlert = false
    @State private var showUpgradeAlert = false
    @State private var disabledDomainAttempted = ""
    
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
                Text(String(localized: "State Sync Title", bundle: langBundle.bundle))
                    .font(.title2.bold())
                
                Spacer()
                
                Toggle(String(localized: "Enable State Sync", bundle: langBundle.bundle), isOn: Binding(
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
                .disabled(isSyncing || appState.syncService.isSyncing || showSuccess || !syncSettings.enabledCategories.wrappedValue.contains(.browserData))
            }
            .padding()

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Sync Warning Header", bundle: langBundle.bundle), systemImage: "info.circle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Group {
                            Text(String(localized: "Sync Warning Reason Detail", bundle: langBundle.bundle))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Participating Browsers", bundle: langBundle.bundle)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Toggle(isOn: Binding(
                                    get: { syncSettings.stateParticipatingBrowsers.wrappedValue.contains(info.browser) },
                                    set: { isParticipating in
                                        if isParticipating {
                                            guard appState.purchaseService.isProUnlocked ||
                                                    syncSettings.wrappedValue.stateParticipatingBrowsers.count < ProLimits.freeSyncBrowserCount else {
                                                showUpgradeAlert = true
                                                return
                                            }
                                            syncSettings.wrappedValue.stateParticipatingBrowsers.insert(info.browser)
                                        } else {
                                            syncSettings.wrappedValue.stateParticipatingBrowsers.remove(info.browser)
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
                                            !syncSettings.stateParticipatingBrowsers.wrappedValue.contains(info.browser) &&
                                            syncSettings.stateParticipatingBrowsers.wrappedValue.count >= ProLimits.freeSyncBrowserCount {
                                            ProBadge()
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }

                Section(String(localized: "Website Options", bundle: langBundle.bundle)) {
                    Picker(String(localized: "Default Strategy", bundle: langBundle.bundle), selection: syncSettings.browserDataSyncStrategy) {
                        ForEach(BrowserDataSyncStrategy.allCases) { strategy in
                            Text(String(localized: String.LocalizationValue(strategy.displayName), bundle: langBundle.bundle)).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if syncSettings.browserDataSyncStrategy.wrappedValue == .primaryWins {
                        Picker(String(localized: "Data Source Browser", bundle: langBundle.bundle), selection: syncSettings.stateSourceBrowser) {
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
                    }
                    
                    Picker(String(localized: "List Policy", bundle: langBundle.bundle), selection: syncSettings.websiteListPolicy) {
                        ForEach(WebsiteListPolicy.allCases) { policy in
                            Text(String(localized: String.LocalizationValue(policy.displayName), bundle: langBundle.bundle)).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Toggle(isOn: Binding(
                        get: { appState.purchaseService.isProUnlocked && syncSettings.automaticSync.wrappedValue },
                        set: { enabled in
                            guard appState.purchaseService.isProUnlocked else {
                                showUpgradeAlert = true
                                syncSettings.automaticSync.wrappedValue = false
                                return
                            }
                            syncSettings.automaticSync.wrappedValue = enabled
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(String(localized: "Real-time Auto Sync", bundle: langBundle.bundle))
                            ProBadge()
                        }
                    }
                        .padding(.vertical, 4)
                    
                    HStack {
                        Text(String(localized: "Website List", bundle: langBundle.bundle))
                            .font(.headline)
                        Spacer()
                        Button {
                            guard appState.purchaseService.isProUnlocked ||
                                    syncSettings.websiteSettings.wrappedValue.count < ProLimits.freeWebsiteRuleCount else {
                                showUpgradeAlert = true
                                return
                            }
                            syncSettings.websiteSettings.wrappedValue.append(WebsiteSyncSetting(domain: "", strategy: nil))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                if !appState.purchaseService.isProUnlocked &&
                                    syncSettings.websiteSettings.wrappedValue.count >= ProLimits.freeWebsiteRuleCount {
                                    ProBadge()
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    
                    ForEach(syncSettings.websiteSettings) { $site in
                        HStack {
                            TextField("", text: $site.domain, prompt: Text(String(localized: "Domain (e.g. example.com)", bundle: langBundle.bundle)))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .onChange(of: $site.domain.wrappedValue) { newValue in
                                    let lower = newValue.lowercased()
                                    if WebsiteSyncSetting.syncDisabledDomains.contains(where: { lower == $0 || lower.hasSuffix(".\($0)") }) {
                                        disabledDomainAttempted = newValue
                                        showDisabledDomainAlert = true
                                        $site.domain.wrappedValue = ""
                                    }
                                }
                            
                            Picker("", selection: $site.strategy) {
                                Text(String(localized: "Default Policy", bundle: langBundle.bundle)).tag(BrowserDataSyncStrategy?.none)
                                ForEach(BrowserDataSyncStrategy.allCases) { s in
                                    Text(String(localized: String.LocalizationValue(s.displayName), bundle: langBundle.bundle)).tag(BrowserDataSyncStrategy?.some(s))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: $site.strategy.wrappedValue) { newValue in
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
                                        Text(String(localized: "Default Source", bundle: langBundle.bundle)).tag(Browser?.none)
                                    }
                                    ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                        Label {
                                            Text(info.displayName)
                                        } icon: {
                                            AppIconImage(appURL: info.appURL)
                                        }
                                        .tag(Browser?.some(info.browser))
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
            .alert(String(localized: "Confirm Delete Rule", bundle: langBundle.bundle), isPresented: Binding(
                get: { siteToDelete != nil },
                set: { if !$0 { siteToDelete = nil } }
            ), presenting: siteToDelete) { site in
                Button(String(localized: "Delete", bundle: langBundle.bundle), role: .destructive) {
                    syncSettings.websiteSettings.wrappedValue.removeAll(where: { $0.id == site.id })
                }
                Button(String(localized: "Cancel", bundle: langBundle.bundle), role: .cancel) {}
            } message: { site in
                Text(String(format: String(localized: "Delete site rule message", bundle: langBundle.bundle), site.domain))
            }
            .alert(String(localized: "Cannot Sync Domain", bundle: langBundle.bundle), isPresented: $showDisabledDomainAlert) {
                Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "The domain '%@' cannot be synced because of its security and authentication mechanisms.", bundle: langBundle.bundle), disabledDomainAttempted))
            }
            .alert(String(localized: "Professional Required", bundle: langBundle.bundle), isPresented: $showUpgradeAlert) {
                Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "Free version supports up to %d sync browsers and %d website rules. Unlock Professional for unlimited sync.", bundle: langBundle.bundle), ProLimits.freeSyncBrowserCount, ProLimits.freeWebsiteRuleCount))
            }
        }
    }
}
