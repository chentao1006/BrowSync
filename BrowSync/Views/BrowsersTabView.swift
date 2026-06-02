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
                HStack(spacing: 12) {
                    if let url = info.appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: info.id.sfSymbol)
                            .font(.title)
                            .frame(width: 32, height: 32)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(info.displayName)
                                .font(.headline)
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
            }
            .listStyle(.inset)
        }
    }
}
