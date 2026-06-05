// SettingsService.swift
// BrowSync — App settings persistence

import Foundation
import ServiceManagement
import os.log

// MARK: - General Settings

struct GeneralSettings: Codable, Equatable {
    var launchAtLogin: Bool = false
    var hideWindowOnStartup: Bool = true
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
    
    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hideWindowOnStartup, menuBarMode, theme, language, notifySyncComplete, notifyBrowserConnected, autoUpdate, analyticsEnabled, analyticsOptInPrompted, firstLaunchDate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hideWindowOnStartup = try container.decodeIfPresent(Bool.self, forKey: .hideWindowOnStartup) ?? true
        menuBarMode = try container.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .alwaysVisible
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        notifySyncComplete = try container.decodeIfPresent(Bool.self, forKey: .notifySyncComplete) ?? true
        notifyBrowserConnected = try container.decodeIfPresent(Bool.self, forKey: .notifyBrowserConnected) ?? true
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        analyticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .analyticsEnabled) ?? false
        analyticsOptInPrompted = try container.decodeIfPresent(Bool.self, forKey: .analyticsOptInPrompted) ?? false
        firstLaunchDate = try container.decodeIfPresent(Date.self, forKey: .firstLaunchDate)
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

private struct SettingsBundle: Codable {
    var general: GeneralSettings
    var sync: SyncSettings
    var router: RouterSettings?
}
