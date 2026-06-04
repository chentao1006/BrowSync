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
                Text("通用设置")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Form {
                // App behavior
                Section("应用行为") {
                    Toggle("登录时自动启动", isOn: Binding(
                        get: { settings.launchAtLogin.wrappedValue },
                        set: { appState.settingsService.applyLaunchAtLogin($0) }
                    ))

                    Toggle("启动时隐藏窗口", isOn: settings.hideWindowOnStartup)
                }

                // Appearance
                Section("外观") {
                    Picker("菜单栏图标", selection: settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("主题", selection: settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .onChange(of: settings.theme.wrappedValue) { _, newTheme in
                        applyTheme(newTheme)
                    }
                }

                // Language
                Section("语言") {
                    Picker("语言", selection: settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    if settings.language.wrappedValue != .system {
                        Text("切换语言将在重启应用后生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Notifications
                Section("通知") {
                    Toggle("同步完成时发送通知", isOn: settings.notifySyncComplete)
                    Toggle("浏览器连接时发送通知", isOn: settings.notifyBrowserConnected)
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
