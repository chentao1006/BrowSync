// SyncView.swift
// BrowSync — Tab 3: Sync settings and controls

import SwiftUI

struct SyncView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var isSyncing = false
    @State private var showUpgradeAlert = false

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
                    Text("Sync")
                        .font(.title2.bold())
                    if let lastSync = appState.syncService.lastSyncDate {
                        Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never synced")
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
                            Text("Syncing…")
                        }
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
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
                    SettingsGroupBox(title: "Bookmark Source Browser",
                                     description: "The primary source of truth for bookmarks") {
                        Picker("Bookmark Source", selection: syncSettings.bookmarkSourceBrowser) {
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
                    SettingsGroupBox(title: "Bookmark Sync Strategy",
                                     description: "How bookmarks should be synced between browsers") {
                        Picker("Bookmark Strategy", selection: syncSettings.bookmarkSyncStrategy) {
                            ForEach(BookmarkSyncStrategy.allCases) { strategy in
                                Text(String(localized: String.LocalizationValue(strategy.displayName), bundle: langBundle.bundle)).tag(strategy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Conflict Strategy
                    SettingsGroupBox(title: "Conflict Strategy",
                                     description: "How to resolve conflicting data between browsers") {
                        Picker("Conflict Strategy", selection: syncSettings.conflictStrategy) {
                            ForEach(ConflictStrategy.allCases) { strategy in
                                Text(String(localized: String.LocalizationValue(strategy.displayName), bundle: langBundle.bundle)).tag(strategy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Browser Data Strategy
                    SettingsGroupBox(title: "Browser Data Sync Strategy",
                                     description: "How to resolve conflicting cookies and local storage") {
                        Picker("Browser Data Strategy", selection: syncSettings.browserDataSyncStrategy) {
                            ForEach(BrowserDataSyncStrategy.allCases) { strategy in
                                Text(String(localized: String.LocalizationValue(strategy.displayName), bundle: langBundle.bundle)).tag(strategy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Website Filtering
                    SettingsGroupBox(title: "Website Filtering",
                                     description: "Control which websites to sync data for") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("List Policy", selection: syncSettings.websiteListPolicy) {
                                ForEach(WebsiteListPolicy.allCases) { policy in
                                    Text(String(localized: String.LocalizationValue(policy.displayName), bundle: langBundle.bundle)).tag(policy)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()

                            Divider()

                            HStack {
                                Text("Website List")
                                    .font(.subheadline.bold())
                                Spacer()
                                Button {
                                    guard appState.purchaseService.isProUnlocked ||
                                            syncSettings.websiteSettings.wrappedValue.count < ProLimits.freeWebsiteRuleCount else {
                                        showUpgradeAlert = true
                                        return
                                    }
                                    syncSettings.websiteSettings.wrappedValue.append(WebsiteSyncSetting(domain: "", strategy: nil))
                                    appState.settingsService.save()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                        if !appState.purchaseService.isProUnlocked &&
                                            syncSettings.websiteSettings.wrappedValue.count >= ProLimits.freeWebsiteRuleCount {
                                            ProBadge()
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(syncSettings.websiteSettings) { $site in
                                HStack {
                                    TextField("Domain (e.g. apple.com)", text: $site.domain)
                                        .textFieldStyle(.roundedBorder)
                                    
                                    Picker("", selection: $site.strategy) {
                                        Text("Default").tag(BrowserDataSyncStrategy?.none)
                                        ForEach(BrowserDataSyncStrategy.allCases) { s in
                                            Text(String(localized: String.LocalizationValue(s.displayName), bundle: langBundle.bundle)).tag(BrowserDataSyncStrategy?.some(s))
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
                    SettingsGroupBox(title: "What to Sync") {
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
                    SettingsGroupBox(title: "Automatic") {
                        VStack(spacing: 0) {
                            ProFeatureRow(
                                title: "Automatic Sync",
                                description: "Sync automatically whenever changes are detected",
                                systemImage: "clock.arrow.circlepath"
                            )
                            Divider().padding(.leading, 52)
                            ProFeatureRow(
                                title: "iCloud Sync",
                                description: "Keep sync data in iCloud across your Macs",
                                systemImage: "icloud"
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(String(localized: "Professional Required", bundle: langBundle.bundle), isPresented: $showUpgradeAlert) {
            Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "Free version supports up to %d website rules. Unlock Professional for unlimited websites.", bundle: langBundle.bundle), ProLimits.freeWebsiteRuleCount))
        }
    }
}

// MARK: - Sync Category Row

struct SyncCategoryRow: View {
    let category: SyncCategory
    let isEnabled: Bool
    var isHistoryNote: Bool = false
    let onToggle: (Bool) -> Void
    @EnvironmentObject var langBundle: LanguageBundle

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.sfSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(String(localized: String.LocalizationValue(category.displayName), bundle: langBundle.bundle))
                        .font(.headline)
                    if isHistoryNote {
                        Text("Off by default")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(String(localized: String.LocalizationValue(category.description), bundle: langBundle.bundle))
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
                    ProBadge()
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
