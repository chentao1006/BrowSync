// AboutView.swift
// BrowSync — Tab 5: About, diagnostics, and export

import SwiftUI
import AppKit

struct AboutView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingExportSuccess = false
    @State private var exportURL: URL? = nil

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(String(localized: "About"))
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // App identity
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(hue: 0.6, saturation: 0.7, brightness: 0.9),
                                            Color(hue: 0.7, saturation: 0.8, brightness: 0.7),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: Color(hue: 0.65, saturation: 0.5, brightness: 0.3).opacity(0.3), radius: 12, x: 0, y: 6)

                        VStack(spacing: 4) {
                            Text("BrowSync")
                                .font(.title.bold())
                            Text(String(localized: "同览"))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("Version \(appVersion) (Build \(buildNumber))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 8)

                    // Links
                    SettingsGroupBox(title: String(localized: "Links")) {
                        VStack(spacing: 0) {
                            LinkRow(title: String(localized: "Website"), url: "https://browsync.app", systemImage: "globe")
                            Divider().padding(.leading, 52)
                            LinkRow(title: "GitHub", url: "https://github.com/chentao1006/browsync", systemImage: "chevron.left.forwardslash.chevron.right")
                            Divider().padding(.leading, 52)
                            LinkRow(title: String(localized: "Privacy Policy"), url: "https://browsync.app/privacy", systemImage: "hand.raised")
                            Divider().padding(.leading, 52)
                            LinkRow(title: String(localized: "Support"), url: "https://browsync.app/support", systemImage: "questionmark.circle")
                        }
                    }

                    // Diagnostics
                    SettingsGroupBox(title: String(localized: "Diagnostics")) {
                        VStack(spacing: 0) {
                            // Open Logs
                            Button {
                                openLogs()
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .frame(width: 32)
                                        .foregroundStyle(.tint)
                                    Text(String(localized: "Open Logs"))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 52)

                            // Export Diagnostics
                            Button {
                                exportDiagnostics()
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                        .frame(width: 32)
                                        .foregroundStyle(.tint)
                                    Text(String(localized: "Export Diagnostics"))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Credits
                    VStack(spacing: 4) {
                        Text(String(localized: "Made with ♥ for multi-browser workflows"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("© 2026 BrowSync. \(String(localized: "All rights reserved."))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 16)
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(String(localized: "Diagnostics Exported"), isPresented: $showingExportSuccess) {
            Button(String(localized: "Show in Finder")) {
                if let url = exportURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Diagnostic report saved successfully."))
        }
    }

    // MARK: - Actions

    private func openLogs() {
        let logsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BrowSync/logs")
        NSWorkspace.shared.open(logsURL)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "browsync-diagnostics-\(ISO8601DateFormatter().string(from: Date()))"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let report = buildDiagnosticsReport()
            if let data = try? JSONEncoder().encode(report) {
                try? data.write(to: url)
                exportURL = url
                showingExportSuccess = true
            }
        }
    }

    private func buildDiagnosticsReport() -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            buildNumber: buildNumber,
            settings: DiagnosticsReport.SettingsSummary(
                launchAtLogin: appState.settingsService.general.launchAtLogin,
                startBackgroundService: appState.settingsService.general.startBackgroundService,
                isDefaultBrowser: appState.defaultBrowserHandler.isDefaultBrowser,
                theme: appState.settingsService.general.theme.rawValue,
                language: appState.settingsService.general.language.rawValue
            ),
            browserStatus: appState.browserInfos.map { info in
                DiagnosticsReport.BrowserStatus(
                    browser: info.browser.rawValue,
                    isInstalled: info.isInstalled,
                    version: info.version,
                    extensionStatus: info.extensionStatus.rawValue
                )
            },
            connectionStatus: DiagnosticsReport.ConnectionStatus(
                daemonRunning: appState.daemon.isRunning,
                connectedBrowsers: Array(appState.daemon.connectedBrowsers.map(\.rawValue))
            ),
            syncLog: appState.syncService.syncLog.suffix(50).map { "\($0.date): \($0.message)" },
            ruleCount: appState.rules.count
            // Note: cookies, history, localStorage, sessionStorage are intentionally excluded
        )
    }
}

// MARK: - Link Row

struct LinkRow: View {
    let title: String
    let url: String
    let systemImage: String

    var body: some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Diagnostics Report

struct DiagnosticsReport: Codable {
    var generatedAt: String
    var appVersion: String
    var buildNumber: String
    var settings: SettingsSummary
    var browserStatus: [BrowserStatus]
    var connectionStatus: ConnectionStatus
    var syncLog: [String]
    var ruleCount: Int

    struct SettingsSummary: Codable {
        var launchAtLogin: Bool
        var startBackgroundService: Bool
        var isDefaultBrowser: Bool
        var theme: String
        var language: String
    }

    struct BrowserStatus: Codable {
        var browser: String
        var isInstalled: Bool
        var version: String?
        var extensionStatus: String
    }

    struct ConnectionStatus: Codable {
        var daemonRunning: Bool
        var connectedBrowsers: [String]
    }
}
