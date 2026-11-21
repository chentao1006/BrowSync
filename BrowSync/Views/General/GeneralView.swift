// GeneralView.swift
// BrowSync — Tab 4: General settings

import SwiftUI

struct GeneralView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var showUpgradeAlert = false
    @State private var showResetExtensionAccess = false

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
                Text(String(localized: "General Settings", bundle: langBundle.bundle))
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Form {
                // App behavior
                Section(String(localized: "App Behavior", bundle: langBundle.bundle)) {
                    Toggle(String(localized: "Launch at Login", bundle: langBundle.bundle), isOn: Binding(
                        get: { settings.launchAtLogin.wrappedValue },
                        set: { appState.settingsService.applyLaunchAtLogin($0) }
                    ))

                    Toggle(String(localized: "Hide Window on Startup", bundle: langBundle.bundle), isOn: settings.hideWindowOnStartup)
                    
                    Toggle(isOn: Binding(
                        get: { appState.purchaseService.isProUnlocked && settings.iCloudSync.wrappedValue },
                        set: { enabled in
                            guard appState.purchaseService.isProUnlocked else {
                                showUpgradeAlert = true
                                settings.iCloudSync.wrappedValue = false
                                return
                            }
                            let wasEnabled = settings.iCloudSync.wrappedValue
                            settings.iCloudSync.wrappedValue = enabled
                            if enabled && !wasEnabled {
                                appState.iCloudSyncManager.didEnableSync()
                            } else if !enabled && wasEnabled {
                                appState.iCloudSyncManager.didDisableSync()
                            }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(String(localized: "iCloud Sync", bundle: langBundle.bundle))
                            ProBadge()
                        }
                    }
                    Text(String(localized: "Synchronize all settings, rules, and open tabs across your Mac devices using iCloud.", bundle: langBundle.bundle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Appearance
                Section(String(localized: "Appearance", bundle: langBundle.bundle)) {
                    Picker(String(localized: "Menu Bar Icon", bundle: langBundle.bundle), selection: settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker(String(localized: "Theme", bundle: langBundle.bundle), selection: settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .onChange(of: settings.theme.wrappedValue) { newTheme in
                        applyTheme(newTheme)
                    }
                }

                // Language
                Section {
                    Picker(selection: settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(verbatim: lang.displayName).tag(lang)
                        }
                    } label: {
                        Text(verbatim: String(localized: "Language", bundle: LanguageBundle.systemBundle))
                    }
                    .onChange(of: settings.language.wrappedValue) { newLang in
                        UserDefaults.standard.set(
                            newLang == .system ? nil : [newLang.rawValue],
                            forKey: "AppleLanguages"
                        )
                        appState.broadcastSettings()
                    }
                } header: {
                    Text(verbatim: String(localized: "Language", bundle: LanguageBundle.systemBundle))
                }

                // Notifications
                Section(String(localized: "Notifications", bundle: langBundle.bundle)) {
                    Toggle(String(localized: "Notify on Sync Complete", bundle: langBundle.bundle), isOn: settings.notifySyncComplete)
                    Toggle(String(localized: "Notify on Browser Connected", bundle: langBundle.bundle), isOn: settings.notifyBrowserConnected)
                }

                Section(String(localized: "Extension Access", bundle: langBundle.bundle)) {
                    Text(String(localized: "Approve each Chrome or Firefox extension once on this Mac. Approved browsers reconnect automatically. Safari connects automatically.", bundle: langBundle.bundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DeniedExtensionConnectionsView(daemon: appState.daemon)
                    Button(String(localized: "Reset Extension Access...", bundle: langBundle.bundle)) {
                        showResetExtensionAccess = true
                    }
                    .confirmationDialog(String(localized: "Reset Extension Access?", bundle: langBundle.bundle), isPresented: $showResetExtensionAccess) {
                        Button(String(localized: "Reset Extension Access", bundle: langBundle.bundle), role: .destructive) {
                            appState.daemon.resetExtensionApprovals()
                        }
                    } message: {
                        Text(String(localized: "All extensions will be disconnected. Chrome and Firefox extensions must be approved again; Safari reconnects automatically. Your sync settings and browser data will be kept.", bundle: langBundle.bundle))
                    }
                }

            }
            .formStyle(.grouped)
            .alert(String(localized: "Professional Required", bundle: langBundle.bundle), isPresented: $showUpgradeAlert) {
                Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
            } message: {
                Text(String(localized: "iCloud Sync is available in Professional.", bundle: langBundle.bundle))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func applyTheme(_ theme: AppTheme) {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct DeniedExtensionConnectionsView: View {
    @ObservedObject var daemon: DaemonServer
    @EnvironmentObject var langBundle: LanguageBundle

    var body: some View {
        ForEach(daemon.deniedBrowserIDs, id: \.self) { browserID in
            if let browser = (Browser.registeredBrowsers(including: AppState.shared.settingsService.general.customBrowsers)).first(where: { $0.id == browserID }) {
                HStack(spacing: 8) {
                    if let appURL = browser.appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    Text(browser.displayName)
                    Spacer()
                    Button(String(localized: "Reauthorize", bundle: langBundle.bundle)) {
                        daemon.reviewDeniedBrowser(browser)
                    }
                    .disabled(!daemon.isRunning)
                }
            }
        }
        ForEach(daemon.unmatchedExtensionReports.keys.sorted(), id: \.self) { key in
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                VStack(alignment: .leading) {
                    Text(String(localized: "BrowSync extension in an unrecognized browser", bundle: langBundle.bundle))
                    // The product name the extension reported, e.g. "zen".
                    Text(verbatim: daemon.unmatchedExtensionReports[key] ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Add this browser in the Browsers tab. The extension connects after you approve it.", bundle: langBundle.bundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        ForEach(daemon.deniedPairingKeys, id: \.self) { key in
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                VStack(alignment: .leading) {
                    Text(key.hasPrefix("gecko.")
                         ? String(localized: "BrowSync extension in a Firefox-based browser", bundle: langBundle.bundle)
                         : String(localized: "BrowSync extension in a Chromium-based browser", bundle: langBundle.bundle))
                    // A short installation ID tells two denied profiles apart.
                    Text(verbatim: String(key.split(separator: ".").last?.prefix(8) ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Reauthorize", bundle: langBundle.bundle)) {
                    daemon.retryDeniedPairing(key)
                }
                .disabled(!daemon.isRunning)
            }
        }
        ForEach(daemon.deniedExtensionOrigins, id: \.self) { origin in
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                Text(origin)
                Spacer()
                Button(String(localized: "Reauthorize", bundle: langBundle.bundle)) {
                    daemon.reviewDeniedOrigin(origin)
                }
                .disabled(!daemon.isRunning)
            }
        }
    }
}
