// BrowsersTabView.swift
// BrowSync — Installed Browsers Tab

import SwiftUI
import SafariServices
import UniformTypeIdentifiers

struct BrowsersTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Installed Browsers", bundle: langBundle.bundle))
                .font(.title2.bold())
                .padding()

            List {
                ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                    BrowserRow(info: info)
                }
                
                Button(action: addCustomBrowser) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text(String(localized: "Add Custom Browser...", bundle: langBundle.bundle))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func addCustomBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.applicationBundle]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        if panel.runModal() == .OK, let url = panel.url {
            guard let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier else { return }
            
            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? 
                              (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                              url.deletingPathExtension().lastPathComponent
                              
            // Only add if it's not already standard or custom
            if !Browser.standardBrowsers.contains(where: { $0.bundleIdentifier == bundleIdentifier }) &&
               !appState.settingsService.general.customBrowsers.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                
                let newBrowser = Browser(
                    id: bundleIdentifier,
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    sfSymbol: "macwindow",
                    extensionBasePath: displayName, // Guessed fallback path
                    isCustom: true
                )
                
                appState.settingsService.general.customBrowsers.append(newBrowser)
                appState.settingsService.save()
                Task {
                    await appState.refreshBrowsers()
                }
            }
        }
    }
}

struct BrowserRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
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
                            Text(String(localized: "Default System", bundle: langBundle.bundle))
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(String(format: String(localized: "Version: %@", bundle: langBundle.bundle), info.version ?? String(localized: "Unknown version", bundle: langBundle.bundle)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    let syncs = getSyncs(for: info.browser)
                    let ruleCount = getRuleCount(for: info.browser)
                    
                    HStack(spacing: 8) {
                        if syncs.isEmpty {
                            Text(String(localized: "Not participating in sync", bundle: langBundle.bundle))
                        } else {
                            Text(String(format: String(localized: "Sync: %@", bundle: langBundle.bundle), syncs.joined(separator: ", ")))
                        }
                        
                        if ruleCount > 0 {
                            Text("·")
                            Text(String(format: String(localized: "Routing rules: %lld", bundle: langBundle.bundle), ruleCount))
                        }
                        
                        if isRoutingFallback(for: info) {
                            Text("·")
                            Text(String(localized: "Routing Fallback", bundle: langBundle.bundle))
                                .foregroundStyle(.green)
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
                        Text(String(localized: "Connecting...", bundle: langBundle.bundle))
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
                            Button(String(localized: "Enable in Safari", bundle: langBundle.bundle)) {
                                if let url = info.appURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.leading, 8)
                        } else {
                            Button(String(localized: "Install Extension", bundle: langBundle.bundle)) {
                                if let url = URL(string: AppConfig.chromiumExtensionWebStoreURL) {
                                    if let appURL = info.appURL {
                                        let config = NSWorkspace.OpenConfiguration()
                                        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                                    } else {
                                        NSWorkspace.shared.open(url)
                                    }
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
            s.append(String(localized: "Synced: bookmarks", bundle: langBundle.bundle))
        }
        if settings.enabledCategories.contains(.browserData) && settings.stateParticipatingBrowsers.contains(browser) {
            s.append(String(localized: "Synced: state", bundle: langBundle.bundle))
        }
        return s
    }
    
    private func getRuleCount(for browser: Browser) -> Int {
        var count = 0
        for rule in appState.routerRules where rule.isEnabled {
            if rule.targetBrowserId == browser.rawValue {
                count += 1
            }
        }
        return count
    }
    
    private func isRoutingFallback(for info: BrowserInfo) -> Bool {
        if let fallbackId = appState.fallbackBrowserId {
            return fallbackId == info.id.rawValue
        }
        if appState.browserInfos.contains(where: { $0.isDefault }) {
            return info.isDefault
        }
        return info.browser == .safari
    }
}
