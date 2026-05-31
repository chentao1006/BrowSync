// GeneralView.swift
// BrowSync — Tab 4: General settings

import SwiftUI

struct GeneralView: View {
    @EnvironmentObject var appState: AppState

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
                Text(String(localized: "General"))
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            Form {
                // App behavior
                Section(String(localized: "App Behavior")) {
                    Toggle(String(localized: "Launch at Login"), isOn: Binding(
                        get: { settings.launchAtLogin.wrappedValue },
                        set: { appState.settingsService.applyLaunchAtLogin($0) }
                    ))

                    Toggle(String(localized: "Start Background Service"), isOn: Binding(
                        get: { settings.startBackgroundService.wrappedValue },
                        set: {
                            settings.wrappedValue.startBackgroundService = $0
                            if $0 { appState.daemon.start() } else { appState.daemon.stop() }
                        }
                    ))
                }

                // Appearance
                Section(String(localized: "Appearance")) {
                    Picker(String(localized: "Menu Bar Icon"), selection: settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker(String(localized: "Theme"), selection: settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .onChange(of: settings.theme.wrappedValue) { _, newTheme in
                        applyTheme(newTheme)
                    }
                }

                // Language
                Section(String(localized: "Language")) {
                    Picker(String(localized: "Language"), selection: settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    if settings.language.wrappedValue != .system {
                        Text(String(localized: "Language change takes effect after restart."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Default Browser
                Section(String(localized: "Default Browser")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Set BrowSync as Default Browser"))
                            Text(String(localized: "BrowSync will receive all http/https links and route them using your rules"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.defaultBrowserHandler.isDefaultBrowser {
                            Button(String(localized: "Restore Safari")) {
                                appState.defaultBrowserHandler.restoreDefaultBrowser()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        } else {
                            Button(String(localized: "Set as Default")) {
                                appState.defaultBrowserHandler.registerAsDefaultBrowser()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // Notifications
                Section(String(localized: "Notifications")) {
                    Toggle(String(localized: "Sync Complete"), isOn: settings.notifySyncComplete)
                    Toggle(String(localized: "Browser Connected"), isOn: settings.notifyBrowserConnected)
                    Toggle(String(localized: "Rule Match"), isOn: settings.notifyRuleMatch)
                }

                // Updates
                Section(String(localized: "Updates")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(String(localized: "Automatically check for updates"), isOn: settings.autoUpdate)
                            Text(String(localized: "Powered by Sparkle (coming soon)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
