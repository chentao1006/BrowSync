// GeneralView.swift
// BrowSync — Tab 4: General settings

import SwiftUI

struct GeneralView: View {
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
                    
                    Toggle(String(localized: "iCloud Sync", bundle: langBundle.bundle), isOn: settings.iCloudSync)
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
                    .onChange(of: settings.theme.wrappedValue) { _, newTheme in
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
                    .onChange(of: settings.language.wrappedValue) { _, newLang in
                        UserDefaults.standard.set(
                            newLang == .system ? nil : [newLang.rawValue],
                            forKey: "AppleLanguages"
                        )
                    }
                } header: {
                    Text(verbatim: String(localized: "Language", bundle: LanguageBundle.systemBundle))
                }

                // Notifications
                Section(String(localized: "Notifications", bundle: langBundle.bundle)) {
                    Toggle(String(localized: "Notify on Sync Complete", bundle: langBundle.bundle), isOn: settings.notifySyncComplete)
                    Toggle(String(localized: "Notify on Browser Connected", bundle: langBundle.bundle), isOn: settings.notifyBrowserConnected)
                }

            }
            .formStyle(.grouped)
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
