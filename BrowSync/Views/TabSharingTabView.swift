// TabSharingTabView.swift
// BrowSync — Tab Sharing Config View

import SwiftUI

struct TabSharingTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @Environment(\.scenePhase) private var scenePhase

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
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
                Text(String(localized: "Tab Sharing", bundle: langBundle.bundle))
                    .font(.title2.bold())
                
                Spacer()
                
                Toggle(String(localized: "Enable Tab Sharing", bundle: langBundle.bundle), isOn: syncSettings.tabSharingEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: syncSettings.tabSharingEnabled.wrappedValue) { _ in
                        appState.broadcastSettings()
                        if syncSettings.tabSharingEnabled.wrappedValue {
                            appState.requestTabSharingPull()
                        }
                    }
            }
            .padding()

            Form {
                Section(String(localized: "Participating Browsers", bundle: langBundle.bundle)) {
                    Text(String(localized: "Select browsers to share their active tabs. Shared tabs will appear in the popup of other extensions.", bundle: langBundle.bundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    HStack(spacing: 6) {
                        Text(String(localized: appState.purchaseService.isProUnlocked ? "Professional shares all open tabs." : "Free version shares only the current active tab.", bundle: langBundle.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !appState.purchaseService.isProUnlocked {
                            ProBadge()
                        }
                    }
                    .padding(.bottom, 4)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Toggle(isOn: Binding(
                                    get: { syncSettings.tabSharingParticipatingBrowsers.wrappedValue.contains(info.browser) },
                                    set: { isParticipating in
                                        if isParticipating {
                                            syncSettings.wrappedValue.tabSharingParticipatingBrowsers.insert(info.browser)
                                        } else {
                                            syncSettings.wrappedValue.tabSharingParticipatingBrowsers.remove(info.browser)
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
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
                
                Section(String(localized: "Currently Open Tabs", bundle: langBundle.bundle)) {
                    let groupedTabs = groupTabsByDeviceAndBrowser()
                    if groupedTabs.isEmpty {
                        Text(String(localized: "No active tabs found.", bundle: langBundle.bundle))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groupedTabs.keys.sorted(), id: \.self) { device in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundStyle(.blue)
                                    Text(device).font(.headline)
                                }
                                ForEach(groupedTabs[device]?.keys.sorted(by: { $0.rawValue < $1.rawValue }) ?? [], id: \.self) { browser in
                                    let tabs = groupedTabs[device]?[browser] ?? []
                                    VStack(alignment: .leading, spacing: 8) {
                                        browserHeader(browser, tabCount: tabs.count)
                                        LazyVGrid(
                                            columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 6)],
                                            alignment: .leading,
                                            spacing: 6
                                        ) {
                                            ForEach(tabs.sorted(by: tabSortOrder)) { tab in
                                                tabCard(tab)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!syncSettings.tabSharingEnabled.wrappedValue)
            .onAppear {
                appState.requestTabSharingPull()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active && syncSettings.tabSharingEnabled.wrappedValue {
                    appState.requestTabSharingPull()
                }
            }
            .onReceive(refreshTimer) { _ in
                guard syncSettings.tabSharingEnabled.wrappedValue else { return }
                appState.requestTabSharingPull()
            }
        }
    }

    private func groupTabsByDeviceAndBrowser() -> [String: [Browser: [BrowserTab]]] {
        var result: [String: [Browser: [BrowserTab]]] = [:]
        for (browser, tabs) in appState.remoteTabsCache {
            for tab in tabs {
                let deviceName = tab.deviceName ?? "Unknown Device"
                result[deviceName, default: [:]][browser, default: []].append(tab)
            }
        }
        return result
    }

    @ViewBuilder
    private func browserHeader(_ browser: Browser, tabCount: Int) -> some View {
        HStack(spacing: 6) {
            if let info = appState.browserInfos.first(where: { $0.browser == browser }), let url = info.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(info.displayName)
            } else {
                Image(systemName: browser.sfSymbol)
                    .frame(width: 16, height: 16)
                Text(browser.displayName)
            }
            Text("\(tabCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func tabCard(_ tab: BrowserTab) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: tab.isActive ? "circle.fill" : "globe")
                .font(.caption)
                .foregroundStyle(tab.isActive ? .blue : .secondary)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? String(localized: "Untitled Tab", bundle: langBundle.bundle) : tab.title)
                    .font(.caption)
                    .lineLimit(1)
                if let url = tab.url, !url.isEmpty {
                    Text(URL(string: url)?.host ?? url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func tabSortOrder(_ lhs: BrowserTab, _ rhs: BrowserTab) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        if lhs.windowId != rhs.windowId { return (lhs.windowId ?? "") < (rhs.windowId ?? "") }
        return lhs.index < rhs.index
    }
}
