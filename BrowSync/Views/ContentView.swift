// ContentView.swift
// BrowSync — Root TabView

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab? = .browsers

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: AppTab.browsers) {
                    Label("浏览器", systemImage: "safari")
                }
                NavigationLink(value: AppTab.stateSync) {
                    Label("状态同步", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink(value: AppTab.bookmarkSync) {
                    Label("书签同步", systemImage: "bookmark")
                }
                NavigationLink(value: AppTab.router) {
                    Label("分流", systemImage: "arrow.triangle.branch")
                }
                NavigationLink(value: AppTab.general) {
                    Label("通用", systemImage: "gearshape")
                }
                NavigationLink(value: AppTab.about) {
                    Label("关于", systemImage: "info.circle")
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
                case .router:
                    RouterTabView()
                case .general:
                    GeneralView()
                case .about:
                    AboutTabView()
                }
            } else {
                Text("请选择项目")
                    .foregroundStyle(.secondary)
            }
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
                
                Section("链接") {
                    Link(destination: URL(string: "https://github.com/chentao1006/browsync")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("在 GitHub 上查看源码")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
