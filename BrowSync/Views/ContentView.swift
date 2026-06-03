// ContentView.swift
// BrowSync — Root TabView

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .browsers

    var body: some View {
        TabView(selection: $selectedTab) {
            BrowsersTabView()
                .tabItem {
                    Label("浏览器", systemImage: "safari")
                }
                .tag(AppTab.browsers)

            StateSyncTabView()
                .tabItem {
                    Label("状态同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(AppTab.stateSync)

            BookmarkSyncTabView()
                .environmentObject(appState.backupService)
                .tabItem {
                    Label("书签同步", systemImage: "bookmark")
                }
                .tag(AppTab.bookmarkSync)

            RouterTabView()
                .tabItem {
                    Label("分流", systemImage: "arrow.triangle.branch")
                }
                .tag(AppTab.router)

            GeneralView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
                .tag(AppTab.general)
                
            AboutTabView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .tag(AppTab.about)
        }
        .task {
            await appState.onAppear()
        }
    }
}

enum AppTab: Hashable {
    case browsers, router, stateSync, bookmarkSync, general, about
}

// MARK: - About Tab View

struct AboutTabView: View {
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
                Text("关于")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

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
                        
                        Text("BrowSync")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
                
                Section("更新") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("自动检查更新", isOn: settings.autoUpdate)
                            Text("由 Sparkle 提供支持")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button("检查更新") {
                        (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
                    }
                }
                
                Section("诊断") {
                    Button("查看日志") {
                        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                            let logsUrl = appSupport.appendingPathComponent("BrowSync/logs")
                            NSWorkspace.shared.open(logsUrl)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
