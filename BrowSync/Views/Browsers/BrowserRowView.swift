// BrowserRowView.swift
// BrowSync — Individual browser status row

import SwiftUI

struct BrowserRowView: View {
    let info: BrowserInfo

    var body: some View {
        HStack(spacing: 16) {
            // Browser icon (using SF Symbols as placeholder)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(browserGradient)
                    .frame(width: 48, height: 48)
                Image(systemName: info.browser.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            // Name + version
            VStack(alignment: .leading, spacing: 2) {
                Text(info.displayName)
                    .font(.headline)
                if let version = info.version {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !info.isInstalled {
                    Text(String(localized: "Not installed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status badge
            StatusBadge(status: info.extensionStatus)

            // Action button
            actionButton
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        switch info.extensionStatus {
        case .notInstalled:
            EmptyView()
        case .extensionRequired:
            Button(String(localized: "Install Extension")) {
                // Open extension installation page
                if let url = extensionInstallURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .extensionDisabled:
            Button(String(localized: "Enable")) {
                openExtensionSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .waitingConnection, .connected:
            EmptyView()
        }
    }

    private var extensionInstallURL: URL? {
        switch info.browser {
        case .safari:
            return URL(string: "x-apple.systempreferences:com.apple.preference.extensions")
        case .chrome:
            return URL(string: "https://chrome.google.com/webstore")
        case .arc:
            return URL(string: "https://chromewebstore.google.com")
        case .edge:
            return URL(string: "https://microsoftedge.microsoft.com/addons")
        case .brave:
            return URL(string: "https://chromewebstore.google.com")
        }
    }

    private func openExtensionSettings() {
        switch info.browser {
        case .safari:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.extensions")!)
        default:
            // Open the browser's extensions page
            if let appURL = info.appURL {
                NSWorkspace.shared.open([URL(string: "chrome://extensions/")!], withApplicationAt: appURL, configuration: .init(), completionHandler: nil)
            }
        }
    }

    private var browserGradient: LinearGradient {
        switch info.browser {
        case .safari:
            return LinearGradient(colors: [Color(hue: 0.55, saturation: 0.8, brightness: 0.95), Color(hue: 0.55, saturation: 0.6, brightness: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .chrome:
            return LinearGradient(colors: [Color(hue: 0.1, saturation: 0.8, brightness: 0.95), Color(hue: 0.08, saturation: 0.7, brightness: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .arc:
            return LinearGradient(colors: [Color(hue: 0.75, saturation: 0.7, brightness: 0.9), Color(hue: 0.65, saturation: 0.8, brightness: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .edge:
            return LinearGradient(colors: [Color(hue: 0.55, saturation: 0.9, brightness: 0.85), Color(hue: 0.6, saturation: 0.7, brightness: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .brave:
            return LinearGradient(colors: [Color(hue: 0.35, saturation: 0.7, brightness: 0.75), Color(hue: 0.4, saturation: 0.6, brightness: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: ExtensionStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .overlay {
                    if status == .connected {
                        Circle()
                            .fill(statusColor.opacity(0.4))
                            .frame(width: 13, height: 13)
                    }
                }
            Text(status.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.12))
        )
    }

    private var statusColor: Color {
        switch status {
        case .notInstalled: return .secondary
        case .extensionRequired: return Color(hue: 0.08, saturation: 0.8, brightness: 0.85)
        case .extensionDisabled: return .red
        case .waitingConnection: return Color(hue: 0.13, saturation: 0.9, brightness: 0.95)
        case .connected: return Color(hue: 0.35, saturation: 0.7, brightness: 0.75)
        }
    }
}
