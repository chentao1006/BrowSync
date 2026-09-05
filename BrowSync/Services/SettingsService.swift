// SettingsService.swift
// BrowSync — App settings persistence

import Foundation
import ServiceManagement
import os.log
import Darwin

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
    
    // Custom Browsers
    var customBrowsers: [Browser] = []
    
    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hideWindowOnStartup, menuBarMode, theme, language, notifySyncComplete, notifyBrowserConnected, autoUpdate, analyticsEnabled, analyticsOptInPrompted, firstLaunchDate, iCloudSync, customBrowsers
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
        customBrowsers = try container.decodeIfPresent([Browser].self, forKey: .customBrowsers) ?? []
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
    case hidden = "hidden"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .alwaysVisible: return "Always Visible"
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
    private static let legacySettingsMigrationKey = "DidMigrateLegacyNonSandboxSettingsV2"
    private static let legacySettingsMigrationStatusKey = "LegacyNonSandboxSettingsMigrationStatus"
    private static let legacyDataMigrationKey = "DidMigrateLegacyNonSandboxDataV1"
    private static let legacyDataMigrationStatusKey = "LegacyNonSandboxDataMigrationStatus"
    private let settingsURL: URL

    @Published var general: GeneralSettings = GeneralSettings()
    @Published var syncSettings: SyncSettings = SyncSettings()
    @Published var routerSettings: RouterSettings = RouterSettings()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let browsyncDir = appSupport.appendingPathComponent("BrowSync")
        try? FileManager.default.createDirectory(at: browsyncDir, withIntermediateDirectories: true)
        settingsURL = browsyncDir.appendingPathComponent("settings.json")
        migrateLegacyNonSandboxSettingsIfNeeded()
        migrateLegacyNonSandboxDataIfNeeded()
        load()
    }

    /// The direct build used to store settings in ~/Library/Application Support/BrowSync.
    /// Once it becomes sandboxed, Application Support resolves inside the app container,
    /// which would otherwise look like a fresh installation and hide existing rules and
    /// feature switches. The direct-build entitlement grants read-only access to this one
    /// legacy directory solely for this migration. Directory access is needed
    /// for the sandbox to resolve the file's parent path.
    private func migrateLegacyNonSandboxSettingsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.legacySettingsMigrationKey) else {
            recordLegacySettingsMigrationStatus("already-migrated-v2")
            return
        }
        guard let userHome = Self.realUserHomeDirectory() else {
            recordLegacySettingsMigrationStatus("user-home-unavailable")
            return
        }

        let legacyURL = userHome
            .appendingPathComponent("Library/Application Support/BrowSync/settings.json")
        guard legacyURL.standardizedFileURL != settingsURL.standardizedFileURL else {
            markLegacySettingsMigrationDone("legacy-path-is-container")
            return
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            markLegacySettingsMigrationDone("legacy-file-not-found")
            return
        }
        let legacyData: Data
        do {
            legacyData = try Data(contentsOf: legacyURL)
        } catch {
            // The file exists but could not be read. Do not mark migration
            // complete: this can be a transient sandbox or disk failure, and
            // giving up would permanently hide an existing user's settings.
            recordLegacySettingsMigrationStatus("legacy-file-unreadable")
            logger.error("Failed to read legacy BrowSync settings: \(error.localizedDescription)")
            return
        }
        let legacySettings: SettingsBundle
        do {
            legacySettings = try JSONDecoder().decode(SettingsBundle.self, from: legacyData)
        } catch {
            markLegacySettingsMigrationDone("legacy-file-invalid")
            logger.error("Failed to decode legacy BrowSync settings: \(error.localizedDescription)")
            return
        }

        let currentSettings = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONDecoder().decode(SettingsBundle.self, from: $0) }
        guard currentSettings.map(Self.hasMeaningfulConfiguration) != true else {
            markLegacySettingsMigrationDone("container-settings-kept")
            return
        }
        guard Self.hasMeaningfulConfiguration(legacySettings) else {
            markLegacySettingsMigrationDone("legacy-settings-empty")
            return
        }

        do {
            try legacyData.write(to: settingsURL, options: .atomicWrite)
            markLegacySettingsMigrationDone("migrated")
            logger.notice("Migrated legacy non-sandbox BrowSync settings into the app container")
        } catch {
            // Leave the flag unset: a write failure (disk full, permissions)
            // is worth retrying on the next launch rather than giving up for good.
            recordLegacySettingsMigrationStatus("container-write-failed")
            logger.error("Failed to migrate legacy BrowSync settings: \(error.localizedDescription)")
        }
    }

    private func markLegacySettingsMigrationDone(_ status: String) {
        UserDefaults.standard.set(true, forKey: Self.legacySettingsMigrationKey)
        recordLegacySettingsMigrationStatus(status)
    }

    private func recordLegacySettingsMigrationStatus(_ status: String) {
        UserDefaults.standard.set(status, forKey: Self.legacySettingsMigrationStatusKey)
        UserDefaults.standard.synchronize()
    }

    /// Besides settings, the direct build persisted bookmark snapshots, backups,
    /// recovery-bin entries, and cached browser data below the same directory.
    /// Sandboxing moves that directory into the app container, so these files must
    /// be brought across before the services that consume them are initialized.
    /// Never overwrite an item already created in the container: a user may have
    /// used a newer build before this migration runs.
    private func migrateLegacyNonSandboxDataIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.legacyDataMigrationKey) else {
            recordLegacyDataMigrationStatus("already-migrated-v1")
            return
        }
        guard let legacyDirectory = Self.legacyBrowSyncDirectoryURL() else {
            recordLegacyDataMigrationStatus("user-home-unavailable")
            return
        }

        let containerDirectory = settingsURL.deletingLastPathComponent()
        guard legacyDirectory.standardizedFileURL != containerDirectory.standardizedFileURL else {
            markLegacyDataMigrationDone("legacy-path-is-container")
            return
        }
        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else {
            markLegacyDataMigrationDone("legacy-directory-not-found")
            return
        }

        // `settings.json` has its own validity-aware migration above. These are
        // the remaining user data files that are read by the running services.
        let persistentItems = ["Backups", "bookmarks", "history", "sites", "global_state.json"]
        do {
            var copiedItemCount = 0
            for item in persistentItems {
                let source = legacyDirectory.appendingPathComponent(item)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = containerDirectory.appendingPathComponent(item)
                copiedItemCount += try copyLegacyItemIfMissing(from: source, to: destination)
            }
            markLegacyDataMigrationDone("migrated-\(copiedItemCount)-items")
            logger.notice("Migrated \(copiedItemCount) legacy BrowSync data items into the app container")
        } catch {
            // A future launch retries the incomplete migration. Already copied
            // files are kept and are never replaced by the legacy copy.
            recordLegacyDataMigrationStatus("copy-failed")
            logger.error("Failed to migrate legacy BrowSync data: \(error.localizedDescription)")
        }
    }

    /// Recursively merge a legacy item into the sandbox container. The legacy
    /// directory is read-only; copies first land in a sibling temporary file so
    /// a failed copy cannot leave a partially-written destination in place.
    private func copyLegacyItemIfMissing(from source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            logger.warning("Skipping symbolic link during legacy data migration: \(source.path)")
            return 0
        }

        if values.isDirectory == true {
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return try children.reduce(0) { count, child in
                count + copyLegacyItemIfMissing(
                    from: child,
                    to: destination.appendingPathComponent(child.lastPathComponent)
                )
            }
        }

        guard !fileManager.fileExists(atPath: destination.path) else { return 0 }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryDestination = destination.deletingLastPathComponent()
            .appendingPathComponent(".browsync-migration-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporaryDestination)
            try fileManager.moveItem(at: temporaryDestination, to: destination)
            return 1
        } catch {
            try? fileManager.removeItem(at: temporaryDestination)
            throw error
        }
    }

    private func recordLegacyDataMigrationStatus(_ status: String) {
        UserDefaults.standard.set(status, forKey: Self.legacyDataMigrationStatusKey)
        UserDefaults.standard.synchronize()
    }

    private func markLegacyDataMigrationDone(_ status: String) {
        UserDefaults.standard.set(true, forKey: Self.legacyDataMigrationKey)
        recordLegacyDataMigrationStatus(status)
    }

    /// `FileManager` and `NSHomeDirectory()` resolve to the sandbox container.
    /// Read the login account's real home directory from the POSIX account
    /// database so the legacy path remains correct after sandbox adoption.
    private static func realUserHomeDirectory() -> URL? {
        guard let account = getpwuid(getuid()), let path = account.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func legacyBrowSyncDirectoryURL() -> URL? {
        realUserHomeDirectory()?.appendingPathComponent("Library/Application Support/BrowSync")
    }

    private static func hasMeaningfulConfiguration(_ settings: SettingsBundle) -> Bool {
        let router = settings.router ?? RouterSettings()
        let sync = settings.sync
        if isKnownBrokenSandboxDefault(router: router, sync: sync, general: settings.general) {
            return false
        }
        return router.isEnabled ||
            router.fallbackBrowserId != nil ||
            !router.rules.isEmpty ||
            sync.bookmarkAutoSync ||
            !sync.bookmarkParticipatingBrowsers.isEmpty ||
            sync.automaticSync ||
            sync.tabSharingEnabled ||
            !sync.tabSharingParticipatingBrowsers.isEmpty ||
            !sync.stateParticipatingBrowsers.isEmpty ||
            !sync.websiteSettings.isEmpty ||
            !settings.general.customBrowsers.isEmpty
    }

    /// A pre-migration test build wrote this exact set of bookmark defaults to
    /// the new sandbox file. It did not represent user choices and must not
    /// block recovery of the real pre-sandbox settings. Any other bookmark
    /// setup remains meaningful and is preserved.
    private static func isKnownBrokenSandboxDefault(
        router: RouterSettings,
        sync: SyncSettings,
        general: GeneralSettings
    ) -> Bool {
        let brokenCategories: Set<SyncCategory> = [.bookmarks, .browserData, .browserState, .localStorage]
        return !router.isEnabled &&
            router.fallbackBrowserId == nil &&
            router.rules.isEmpty &&
            sync.bookmarkAutoSync &&
            sync.bookmarkParticipatingBrowsers == [.safari, .chrome] &&
            sync.bookmarkSyncStrategy == .oneWay &&
            sync.bookmarkSourceBrowser == .safari &&
            sync.browserDataSyncStrategy == .latestWins &&
            sync.stateSourceBrowser == .safari &&
            sync.websiteListPolicy == .allowList &&
            sync.websiteSettings.isEmpty &&
            !sync.automaticSync &&
            !sync.tabSharingEnabled &&
            sync.tabSharingParticipatingBrowsers.isEmpty &&
            sync.stateParticipatingBrowsers.isEmpty &&
            sync.enabledCategories == brokenCategories &&
            general.customBrowsers.isEmpty
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
