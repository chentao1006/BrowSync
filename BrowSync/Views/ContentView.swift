// ContentView.swift
// BrowSync — Root TabView

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var selectedTab: AppTab? = .browsers

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: AppTab.browsers) {
                    Label(String(localized: "Browsers", bundle: langBundle.bundle), systemImage: "safari")
                }
                NavigationLink(value: AppTab.router) {
                    Label(String(localized: "Link Router", bundle: langBundle.bundle), systemImage: "link")
                }
                NavigationLink(value: AppTab.bookmarkSync) {
                    Label(String(localized: "Bookmark Sync", bundle: langBundle.bundle), systemImage: "bookmark")
                }
                NavigationLink(value: AppTab.stateSync) {
                    Label(String(localized: "State Sync", bundle: langBundle.bundle), systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink(value: AppTab.tabSharing) {
                    Label(String(localized: "Tab Sharing", bundle: langBundle.bundle), systemImage: "square.and.arrow.up.on.square")
                }
                NavigationLink(value: AppTab.general) {
                    Label(String(localized: "General", bundle: langBundle.bundle), systemImage: "gearshape")
                }
                NavigationLink(value: AppTab.pro) {
                    Label(String(localized: "Professional", bundle: langBundle.bundle), systemImage: "sparkles")
                }
                NavigationLink(value: AppTab.about) {
                    Label(String(localized: "About", bundle: langBundle.bundle), systemImage: "info.circle")
                }
            }
            .navigationTitle("BrowSync")
        } detail: {
            if let selectedTab {
                switch selectedTab {
                case .browsers:
                    BrowsersTabView()
                case .stateSync:
                    StateSyncTabView()
                case .bookmarkSync:
                    BookmarkSyncTabView()
                        .environmentObject(appState.backupService)
                case .tabSharing:
                    TabSharingTabView()
                case .router:
                    RouterTabView()
                case .general:
                    GeneralView()
                case .pro:
                    ProTabView()
                case .about:
                    AboutTabView()
                }
            } else {
                Text(String(localized: "Select an item", bundle: langBundle.bundle))
                    .foregroundStyle(.secondary)
            }
        }
        // Note: locale is set by BrowSyncApp via .environment(\.locale) — do NOT add another one here
    }
}

enum AppTab: Hashable {
    case browsers, router, stateSync, bookmarkSync, tabSharing, general, pro, about
}

// MARK: - About Tab View

struct AboutTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle

    private var settings: Binding<GeneralSettings> {
        Binding(
            get: { appState.settingsService.general },
            set: { appState.settingsService.general = $0; appState.settingsService.save() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(String(localized: "About", bundle: langBundle.bundle))
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Form {
                Section {
                    VStack(alignment: .center, spacing: 12) {
                        if let nsImage = NSImage(named: "AppIcon") {
                            Image(nsImage: nsImage)
                                .resizable()
                                .frame(width: 80, height: 80)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .resizable()
                                .frame(width: 80, height: 80)
                                .foregroundStyle(.blue)
                        }
                        
                        let appName = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                            ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
                            ?? "BrowSync"
                        
                        Text(appName)
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        Text(String(format: String(localized: "Version %@ (%@)", bundle: langBundle.bundle),
                                    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                                    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
                
#if !APP_STORE
                Section(String(localized: "Updates", bundle: langBundle.bundle)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(String(localized: "Check for updates automatically", bundle: langBundle.bundle), isOn: settings.autoUpdate)
                                .onChange(of: settings.autoUpdate.wrappedValue) { newValue in
                                    AppDelegate.shared.updaterController.updater.automaticallyChecksForUpdates = newValue
                                }
                        }
                    }
                    
                    Button(String(localized: "Check for Updates", bundle: langBundle.bundle)) {
                        AppDelegate.shared.updaterController.checkForUpdates(nil)
                    }
                }
#endif
                
                Section(String(localized: "Diagnostics", bundle: langBundle.bundle)) {
                    Button(String(localized: "View Logs", bundle: langBundle.bundle)) {
                        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                            let logsUrl = appSupport.appendingPathComponent("BrowSync/logs")
                            NSWorkspace.shared.open(logsUrl)
                        }
                    }
                }
                
                Section(String(localized: "Analytics", bundle: langBundle.bundle)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(String(localized: "Send Anonymous Usage Statistics", bundle: langBundle.bundle), isOn: settings.analyticsEnabled)
                                .onChange(of: settings.analyticsEnabled.wrappedValue) { newValue in
                                    appState.settingsService.general.analyticsOptInPrompted = true
                                    appState.settingsService.save()
                                    if newValue {
                                        AnalyticsManager.shared.trackEvent("Analytics Enabled")
                                    }
                                }
                            Text(String(localized: "Help us improve BrowSync by sending anonymous usage data.", bundle: langBundle.bundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section(String(localized: "Links", bundle: langBundle.bundle)) {
                    Link(destination: URL(string: "https://github.com/chentao1006/browsync")!) {
                        HStack {
                            Image(systemName: "link")
                            Text(String(localized: "View source code on GitHub", bundle: langBundle.bundle))
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
