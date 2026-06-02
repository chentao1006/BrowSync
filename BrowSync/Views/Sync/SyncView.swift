// SyncView.swift
// BrowSync — Tab 3: Sync settings and controls

import SwiftUI

struct SyncView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSyncing = false

    private var syncSettings: Binding<SyncSettings> {
        Binding(
            get: { appState.settingsService.syncSettings },
            set: { appState.settingsService.syncSettings = $0; appState.settingsService.save() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Sync"))
                        .font(.title2.bold())
                    if let lastSync = appState.syncService.lastSyncDate {
                        Text(String(localized: "Last synced \(lastSync.formatted(.relative(presentation: .named)))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Never synced"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                // Sync Now button
                Button {
                    Task {
                        isSyncing = true
                        await appState.syncAll()
                        isSyncing = false
                    }
                } label: {
                    if isSyncing || appState.syncService.isSyncing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Syncing…"))
                        }
                    } else {
                        Label(String(localized: "Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSyncing || appState.syncService.isSyncing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Bookmark Source Browser
                    SettingsGroupBox(title: String(localized: "Bookmark Source Browser"),
                                     description: String(localized: "The primary source of truth for bookmarks")) {
                        Picker(String(localized: "Bookmark Source"), selection: syncSettings.bookmarkSourceBrowser) {
                            ForEach(Browser.allCases) { browser in
                                HStack {
                                    Image(systemName: browser.sfSymbol)
                                    Text(browser.displayName)
                                }.tag(browser)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Bookmark Sync Strategy
                    SettingsGroupBox(title: String(localized: "Bookmark Sync Strategy"),
                                     description: String(localized: "How bookmarks should be synced between browsers")) {
                        Picker(String(localized: "Bookmark Strategy"), selection: syncSettings.bookmarkSyncStrategy) {
                            ForEach(BookmarkSyncStrategy.allCases) { strategy in
                                Text(strategy.displayName).tag(strategy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Conflict Strategy
                    SettingsGroupBox(title: String(localized: "Conflict Strategy"),
                                     description: String(localized: "How to resolve conflicting data between browsers")) {
                        Picker(String(localized: "Conflict Strategy"), selection: syncSettings.conflictStrategy) {
                            ForEach(ConflictStrategy.allCases) { strategy in
                                Text(strategy.displayName).tag(strategy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Browser Data Strategy
                    SettingsGroupBox(title: String(localized: "Browser Data Sync Strategy"),
                                     description: String(localized: "How to resolve conflicting cookies and local storage")) {
                        Picker(String(localized: "Browser Data Strategy"), selection: syncSettings.browserDataSyncStrategy) {
                            ForEach(BrowserDataSyncStrategy.allCases) { strategy in
                                Text(strategy.displayName).tag(strategy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Website Filtering
                    SettingsGroupBox(title: String(localized: "Website Filtering"),
                                     description: String(localized: "Control which websites to sync data for")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(String(localized: "List Policy"), selection: syncSettings.websiteListPolicy) {
                                ForEach(WebsiteListPolicy.allCases) { policy in
                                    Text(policy.displayName).tag(policy)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()

                            Divider()

                            HStack {
                                Text(String(localized: "Website List"))
                                    .font(.subheadline.bold())
                                Spacer()
                                Button {
                                    syncSettings.websiteSettings.wrappedValue.append(WebsiteSyncSetting(domain: "", strategy: nil))
                                    appState.settingsService.save()
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(syncSettings.websiteSettings) { $site in
                                HStack {
                                    TextField(String(localized: "Domain (e.g. apple.com)"), text: $site.domain)
                                        .textFieldStyle(.roundedBorder)
                                    
                                    Picker("", selection: $site.strategy) {
                                        Text(String(localized: "Default")).tag(BrowserDataSyncStrategy?.none)
                                        ForEach(BrowserDataSyncStrategy.allCases) { s in
                                            Text(s.displayName).tag(BrowserDataSyncStrategy?.some(s))
                                        }
                                    }
                                    .labelsHidden()

                                    Button(role: .destructive) {
                                        syncSettings.websiteSettings.wrappedValue.removeAll(where: { $0.id == $site.wrappedValue.id })
                                        appState.settingsService.save()
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Sync Categories
                    SettingsGroupBox(title: String(localized: "What to Sync")) {
                        VStack(spacing: 0) {
                            ForEach(SyncCategory.allCases) { category in
                                SyncCategoryRow(
                                    category: category,
                                    isEnabled: syncSettings.enabledCategories.wrappedValue.contains(category),
                                    isHistoryNote: category == .history
                                ) { enabled in
                                    if enabled {
                                        syncSettings.wrappedValue.enabledCategories.insert(category)
                                    } else {
                                        syncSettings.wrappedValue.enabledCategories.remove(category)
                                    }
                                    appState.settingsService.save()
                                }

                                if category != SyncCategory.allCases.last {
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                    }

                    // PRO Features
                    SettingsGroupBox(title: String(localized: "Automatic")) {
                        VStack(spacing: 0) {
                            ProFeatureRow(
                                title: String(localized: "Automatic Sync"),
                                description: String(localized: "Sync automatically whenever changes are detected"),
                                systemImage: "clock.arrow.circlepath"
                            )
                            Divider().padding(.leading, 52)
                            ProFeatureRow(
                                title: String(localized: "iCloud Sync"),
                                description: String(localized: "Keep sync data in iCloud across your Macs"),
                                systemImage: "icloud"
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Sync Category Row

struct SyncCategoryRow: View {
    let category: SyncCategory
    let isEnabled: Bool
    var isHistoryNote: Bool = false
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.sfSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(category.displayName)
                        .font(.headline)
                    if isHistoryNote {
                        Text(String(localized: "Off by default"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}

// MARK: - PRO Feature Row

struct ProFeatureRow: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("PRO")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: .constant(false))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(true)
                .opacity(0.4)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}

// MARK: - Settings Group Box

struct SettingsGroupBox<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
