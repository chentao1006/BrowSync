// TabSharingTabView.swift
// BrowSync — Tab Sharing Config View

import SwiftUI

struct TabSharingTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    
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
                    }
            }
            .padding()

            Form {
                Section(String(localized: "Participating Browsers", bundle: langBundle.bundle)) {
                    Text(String(localized: "Select browsers to share their active tabs. Shared tabs will appear in the popup of other extensions.", bundle: langBundle.bundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                
                Section(String(localized: "Overview", bundle: langBundle.bundle)) {
                    // Provide a quick overview of currently cached tabs in the daemon
                    let remoteTabsCount = appState.remoteTabsCache.values.map { $0.count }.reduce(0, +)
                    HStack {
                        Text(String(localized: "Cached Remote Tabs:", bundle: langBundle.bundle))
                        Spacer()
                        Text("\(remoteTabsCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!syncSettings.tabSharingEnabled.wrappedValue)
        }
    }
}
