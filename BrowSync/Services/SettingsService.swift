// SettingsService.swift
// BrowSync — App settings persistence

import Foundation
import ServiceManagement
import os.log

// MARK: - General Settings

struct GeneralSettings: Codable, Equatable {
    var launchAtLogin: Bool = false
    var hideWindowOnStartup: Bool = false
    var menuBarMode: MenuBarMode = .alwaysVisible
    var theme: AppTheme = .system
    var language: AppLanguage = .system

    // Notifications
    var notifySyncComplete: Bool = true
    var notifyBrowserConnected: Bool = true

    // Auto update (Sparkle placeholder)
    var autoUpdate: Bool = true
    
    // Analytics
    var analyticsEnabled: Bool = false
    var analyticsOptInPrompted: Bool = false
    var firstLaunchDate: Date? = nil
    
    // Sync
    var iCloudSync: Bool = false
    
    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hideWindowOnStartup, menuBarMode, theme, language, notifySyncComplete, notifyBrowserConnected, autoUpdate, analyticsEnabled, analyticsOptInPrompted, firstLaunchDate, iCloudSync
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hideWindowOnStartup = try container.decodeIfPresent(Bool.self, forKey: .hideWindowOnStartup) ?? false
        menuBarMode = try container.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .alwaysVisible
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        notifySyncComplete = try container.decodeIfPresent(Bool.self, forKey: .notifySyncComplete) ?? true
        notifyBrowserConnected = try container.decodeIfPresent(Bool.self, forKey: .notifyBrowserConnected) ?? true
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        analyticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .analyticsEnabled) ?? false
        analyticsOptInPrompted = try container.decodeIfPresent(Bool.self, forKey: .analyticsOptInPrompted) ?? false
        firstLaunchDate = try container.decodeIfPresent(Date.self, forKey: .firstLaunchDate)
        iCloudSync = try container.decodeIfPresent(Bool.self, forKey: .iCloudSync) ?? false
    }
}

// MARK: - Router Settings

struct RouterSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var fallbackBrowserId: String? = nil
    var rules: [RouterRule] = []
}

enum MenuBarMode: String, CaseIterable, Codable, Identifiable {
    case alwaysVisible = "always_visible"
    case hideWhenConnected = "hide_when_connected"
    case hidden = "hidden"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .alwaysVisible: return "Always Visible"
        case .hideWhenConnected: return "Hide When Connected"
        case .hidden: return "Hidden"
        }
    }
}

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system = "system"
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case italian = "it"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: 
            return String(localized: "System", bundle: LanguageBundle.systemBundle)
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        }
    }
}

// MARK: - Settings Service

@MainActor
final class SettingsService: ObservableObject {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SettingsService")
    private let settingsURL: URL

    @Published var general: GeneralSettings = GeneralSettings()
    @Published var syncSettings: SyncSettings = SyncSettings()
    @Published var routerSettings: RouterSettings = RouterSettings()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let browsyncDir = appSupport.appendingPathComponent("BrowSync")
        try? FileManager.default.createDirectory(at: browsyncDir, withIntermediateDirectories: true)
        settingsURL = browsyncDir.appendingPathComponent("settings.json")
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: settingsURL) else {
            logger.info("No settings file found, using defaults")
            return
        }
        do {
            let saved = try JSONDecoder().decode(SettingsBundle.self, from: data)
            general = saved.general
            syncSettings = saved.sync
            routerSettings = saved.router ?? RouterSettings()
            // Migration: add any new defaultEnabled categories not in saved settings
            let allDefault = Set(SyncCategory.allCases.filter { $0.defaultEnabled })
            let missing = allDefault.subtracting(syncSettings.enabledCategories)
            if !missing.isEmpty {
                syncSettings.enabledCategories.formUnion(missing)
                logger.info("Migrated new sync categories: \(missing.map(\.rawValue).joined(separator: ", "))")
                save()
            }
        } catch {
            logger.error("Failed to load settings: \(error)")
        }
    }

    func save() {
        do {
            let bundle = SettingsBundle(general: general, sync: syncSettings, router: routerSettings)
            let data = try JSONEncoder().encode(bundle)
            try data.write(to: settingsURL, options: .atomicWrite)
            
            // Push to iCloud if enabled
            Task { @MainActor in
                AppState.shared.iCloudSyncManager.uploadSettings(from: self)
            }
        } catch {
            logger.error("Failed to save settings: \(error)")
        }
    }

    // MARK: - Launch at Login

    func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            general.launchAtLogin = enabled
            save()
            logger.info("Launch at login: \(enabled)")
        } catch {
            logger.error("SMAppService error: \(error)")
        }
    }
}

// MARK: - Settings Bundle (Codable wrapper)

struct SettingsBundle: Codable {
    var general: GeneralSettings
    var sync: SyncSettings
    var router: RouterSettings?
}
// ICloudSyncManager.swift
// BrowSync — iCloud Synchronization

import Foundation
import os.log

@MainActor
final class ICloudSyncManager: ObservableObject {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "ICloudSyncManager")
    
    // Using NSUbiquitousKeyValueStore.default
    private let kvStore = NSUbiquitousKeyValueStore.default
    
    // Keys
    private let settingsKey = "browsync_settings"
    private let tabsPrefix = "browsync_tabs_"
    
    // The local device ID
    private let deviceID: String
    
    // Prevent upload loops
    private var isDownloadingRemoteTabs = false
    private var isDownloadingSettings = false
    
    // Dependencies
    private weak var settingsService: SettingsService?
    
    init() {
        self.deviceID = Host.current().localizedName ?? UUID().uuidString
        logger.info("ICloudSyncManager initialized with device ID: \(self.deviceID)")
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        
        // Trigger initial sync
        kvStore.synchronize()
    }
    
    func setup(settingsService: SettingsService) {
        self.settingsService = settingsService
        
        Task { @MainActor in
            if settingsService.general.iCloudSync && AppState.shared.purchaseService.isProUnlocked {
                downloadSettings()
                downloadRemoteTabs()
                uploadSettings(from: settingsService)
            }
        }
    }
    
    // MARK: - Upload Settings
    
    func uploadSettings(from service: SettingsService) {
        guard service.general.iCloudSync else { return }
        guard AppState.shared.purchaseService.isProUnlocked else { return }
        guard !isDownloadingSettings else { return }
        
        do {
            let bundle = SettingsBundle(general: service.general, sync: service.syncSettings, router: service.routerSettings)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(bundle)
            
            if let existing = kvStore.data(forKey: settingsKey), existing == data {
                return
            }
            
            kvStore.set(data, forKey: settingsKey)
            kvStore.synchronize()
            logger.info("Uploaded settings to iCloud.")
        } catch {
            logger.error("Failed to encode settings for iCloud: \(error)")
        }
    }
    
    // MARK: - Upload Tabs
    
    func uploadTabs(_ tabsCache: [Browser: [BrowserTab]]) {
        guard let service = settingsService, service.general.iCloudSync else { return }
        guard AppState.shared.purchaseService.isProUnlocked else { return }
        guard !isDownloadingRemoteTabs else { return }
        
        // Only upload truly local tabs, filter out remote iCloud tabs
        var localTabsToUpload: [Browser: [BrowserTab]] = [:]
        let isProUnlocked = AppState.shared.purchaseService.isProUnlocked
        for (browser, tabs) in tabsCache {
            let localTabs = tabs.filter { !$0.id.hasPrefix("icloud_") }
            localTabsToUpload[browser] = ProLimits.limitedTabsForSharing(localTabs, isProUnlocked: isProUnlocked)
        }
        
        let key = tabsPrefix + deviceID
        do {
            // Encode the tabs dictionary
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(localTabsToUpload)
            
            if let existing = kvStore.data(forKey: key), existing == data {
                return
            }
            
            kvStore.set(data, forKey: key)
            kvStore.synchronize()
            logger.info("Uploaded tabs to iCloud for device: \(self.deviceID)")
        } catch {
            logger.error("Failed to encode tabs for iCloud: \(error)")
        }
    }
    
    // MARK: - iCloud Observations
    
    @objc private func storeDidChange(_ notification: Notification) {
        Task { @MainActor in
            guard let service = settingsService, service.general.iCloudSync else { return }
            guard AppState.shared.purchaseService.isProUnlocked else { return }
            
            guard let userInfo = notification.userInfo else { return }
            guard let reasonForChange = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else { return }
            
            // We can check changed keys, but for simplicity we'll just check if settings or tabs changed
            guard let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
            
            logger.info("iCloud store changed remotely: \(changedKeys)")
            
            if changedKeys.contains(settingsKey) {
                downloadSettings()
            }
            
            if changedKeys.contains(where: { $0.hasPrefix(tabsPrefix) && $0 != tabsPrefix + deviceID }) {
                downloadRemoteTabs()
            }
        }
    }
    
    private func downloadSettings() {
        guard let service = settingsService else { return }
        guard AppState.shared.purchaseService.isProUnlocked else { return }
        guard let data = kvStore.data(forKey: settingsKey) else { return }
        
        do {
            let remoteBundle = try JSONDecoder().decode(SettingsBundle.self, from: data)
            let wasSyncEnabled = service.general.iCloudSync
            
            isDownloadingSettings = true
            
            // General Settings: latest wins
            service.general = remoteBundle.general
            service.general.iCloudSync = wasSyncEnabled
            
            // Router Settings: Use remote
            service.routerSettings.isEnabled = remoteBundle.router?.isEnabled ?? service.routerSettings.isEnabled
            service.routerSettings.fallbackBrowserId = remoteBundle.router?.fallbackBrowserId ?? service.routerSettings.fallbackBrowserId
            service.routerSettings.rules = remoteBundle.router?.rules ?? []
            
            // Sync Settings: Merge collections
            let remoteSync = remoteBundle.sync
            service.syncSettings.conflictStrategy = remoteSync.conflictStrategy
            service.syncSettings.bookmarkSyncStrategy = remoteSync.bookmarkSyncStrategy
            service.syncSettings.bookmarkSourceBrowser = remoteSync.bookmarkSourceBrowser
            service.syncSettings.bookmarkAutoSync = remoteSync.bookmarkAutoSync
            service.syncSettings.browserDataSyncStrategy = remoteSync.browserDataSyncStrategy
            service.syncSettings.stateSourceBrowser = remoteSync.stateSourceBrowser
            service.syncSettings.websiteListPolicy = remoteSync.websiteListPolicy
            service.syncSettings.tabSharingEnabled = remoteSync.tabSharingEnabled
            service.syncSettings.automaticSync = remoteSync.automaticSync
            
            // Sync Collections: Use remote
            service.syncSettings.bookmarkParticipatingBrowsers = remoteSync.bookmarkParticipatingBrowsers
            service.syncSettings.stateParticipatingBrowsers = remoteSync.stateParticipatingBrowsers
            service.syncSettings.tabSharingParticipatingBrowsers = remoteSync.tabSharingParticipatingBrowsers
            service.syncSettings.enabledCategories = remoteSync.enabledCategories
            
            // Website Settings: Use remote
            service.syncSettings.websiteSettings = remoteSync.websiteSettings
            
            service.save() // Save locally
            isDownloadingSettings = false
            
            logger.info("Successfully applied and merged iCloud settings to local store.")
            
            // Because save() skips iCloud upload during isDownloadingSettings, we should explicitly upload the *merged* result 
            // once, so that the remote iCloud store gets the union of our local settings and the remote ones.
            Task { @MainActor in
                self.uploadSettings(from: service)
            }
            
            // Inform AppState to broadcast
            AppState.shared.broadcastSettings()
            
            // Because router rules might have changed:
            AppState.shared.routerRules = service.routerSettings.rules
            AppState.shared.isRouterEnabled = service.routerSettings.isEnabled
            AppState.shared.fallbackBrowserId = service.routerSettings.fallbackBrowserId
            
        } catch {
            isDownloadingSettings = false
            logger.error("Failed to decode remote settings: \(error)")
        }
    }
    
    func downloadRemoteTabs() {
        guard let service = settingsService, service.general.iCloudSync else { return }
        guard AppState.shared.purchaseService.isProUnlocked else { return }
        
        let allKeys = kvStore.dictionaryRepresentation.keys.filter { $0.hasPrefix(tabsPrefix) && $0 != tabsPrefix + deviceID }
        
        var mergedTabs: [Browser: [BrowserTab]] = [:]
        
        // Start with current local daemon cache
        let localCache = AppState.shared.remoteTabsCache
        
        for key in allKeys {
            if let data = kvStore.data(forKey: key) {
                do {
                    let remoteDeviceTabs = try JSONDecoder().decode([Browser: [BrowserTab]].self, from: data)
                    let remoteDeviceName = key.replacingOccurrences(of: tabsPrefix, with: "")
                    
                    for (browser, tabs) in remoteDeviceTabs {
                        // Append device name to windowId or tab title to distinguish them?
                        // Actually, we can just append them to the list of tabs for that browser.
                        // Or modify the windowId so we know it's remote.
                        let markedTabs = tabs.map { tab -> BrowserTab in
                            var modifiedTab = tab
                            modifiedTab.id = "icloud_\(remoteDeviceName)_\(tab.id)"
                            modifiedTab.title = "[\(remoteDeviceName)] \(tab.title)"
                            modifiedTab.deviceName = remoteDeviceName
                            return modifiedTab
                        }
                        
                        mergedTabs[browser, default: []].append(contentsOf: markedTabs)
                    }
                } catch {
                    logger.error("Failed to decode remote tabs from \(key): \(error)")
                }
            }
        }
        
        let localDeviceName = Host.current().localizedName ?? "Local Device"
        
        // Now merge local and remote
        for (browser, tabs) in localCache {
            let purelyLocalTabs = tabs.filter { !$0.id.hasPrefix("icloud_") }.map { tab -> BrowserTab in
                var modifiedTab = tab
                modifiedTab.deviceName = localDeviceName
                return modifiedTab
            }
            mergedTabs[browser, default: []].insert(contentsOf: purelyLocalTabs, at: 0)
        }
        
        isDownloadingRemoteTabs = true
        AppState.shared.remoteTabsCache = mergedTabs
        isDownloadingRemoteTabs = false
        
        logger.info("Merged remote iCloud tabs into AppState.")
    }
}
