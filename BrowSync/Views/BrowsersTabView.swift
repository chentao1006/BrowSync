// BrowsersTabView.swift
// BrowSync — Installed Browsers Tab

import SwiftUI
import SafariServices

struct BrowsersTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已安装的浏览器")
                .font(.title2.bold())
                .padding()

            List(appState.browserInfos.filter { $0.isInstalled }) { info in
                BrowserRow(info: info)
            }
            .listStyle(.inset)
        }
    }
}

struct BrowserRow: View {
    @EnvironmentObject var appState: AppState
    let info: BrowserInfo
    
    @State private var isHovering = false
    
    var body: some View {
        Button {
            if let url = info.appURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                if let url = info.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: info.id.sfSymbol)
                        .font(.system(size: 40))
                        .frame(width: 56, height: 56)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(info.displayName)
                            .font(.title3.bold())
                        if info.isDefault {
                            Text("(系统默认)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text("版本: \(info.version ?? "未知版本")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    let syncs = getSyncs(for: info.browser)
                    let ruleCount = getRuleCount(for: info.browser)
                    
                    HStack(spacing: 8) {
                        Text(syncs.isEmpty ? "未参与同步" : "同步: \(syncs.joined(separator: ", "))")
                        
                        if ruleCount > 0 {
                            Text("·")
                            Text("分流规则: \(ruleCount)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Spacer(minLength: 16)
                
                if info.extensionStatus == .waitingConnection {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("连接中...")
                            .foregroundStyle(.secondary)
                    }
                } else if info.extensionStatus == .offline {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.zzz.fill")
                        Text(info.extensionStatus.displayName)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: info.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(info.extensionStatus.displayName)
                    }
                    .foregroundStyle(info.isConnected ? .green : .orange)
                    
                    if info.extensionStatus == .notInstalled || info.extensionStatus == .extensionRequired || info.extensionStatus == .extensionDisabled {
                        // Action Buttons inline
                        if info.browser == .safari {
                            Button("在 Safari 中启用") {
                                if let url = info.appURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.leading, 8)
                        } else {
                            Button("安装扩展") {
                                if let url = URL(string: AppConfig.chromiumExtensionWebStoreURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.leading, 8)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isHovering ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    private func getSyncs(for browser: Browser) -> [String] {
        let settings = appState.settingsService.syncSettings
        var s: [String] = []
        if settings.enabledCategories.contains(.bookmarks) && settings.bookmarkParticipatingBrowsers.contains(browser) {
            s.append("书签")
        }
        if settings.enabledCategories.contains(.browserData) && settings.stateParticipatingBrowsers.contains(browser) {
            s.append("状态")
        }
        return s
    }
    
    private func getRuleCount(for browser: Browser) -> Int {
        let settings = appState.settingsService.syncSettings
        var count = 0
        if settings.bookmarkSyncStrategy == .oneWay && settings.bookmarkSourceBrowser == browser {
            count += 1
        }
        if settings.browserDataSyncStrategy == .primaryWins && settings.stateSourceBrowser == browser {
            count += 1
        }
        count += settings.websiteSettings.filter { $0.sourceBrowser == browser }.count
        return count
    }
}
