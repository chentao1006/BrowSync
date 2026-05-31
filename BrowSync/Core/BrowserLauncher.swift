// BrowserLauncher.swift
// BrowSync — Opens URLs in specific browsers

import Foundation
import AppKit
import os.log

final class BrowserLauncher {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "BrowserLauncher")

    // MARK: - Open URL

    @discardableResult
    func open(_ url: URL, in browser: Browser, profile: String? = nil) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
            logger.warning("Browser not installed: \(browser.rawValue)")
            return false
        }

        var configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let profile, browser.supportsProfiles {
            let profiled = profileConfiguration(for: browser, profile: profile, base: configuration)
            configuration = profiled
        }

        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { [weak self] app, error in
            if let error {
                self?.logger.error("Failed to open \(url) in \(browser.rawValue): \(error)")
            }
        }

        return true
    }

    // MARK: - Profile Configuration

    private func profileConfiguration(
        for browser: Browser,
        profile: String,
        base: NSWorkspace.OpenConfiguration
    ) -> NSWorkspace.OpenConfiguration {
        // Chrome/Edge/Brave support --profile-directory=<name>
        // Arc uses spaces differently — profile support is limited
        var config = base
        switch browser {
        case .chrome, .edge, .brave:
            config.arguments = ["--profile-directory=\(profile)"]
        default:
            break
        }
        return config
    }
}

// MARK: - Browser Profile Support

extension Browser {
    var supportsProfiles: Bool {
        switch self {
        case .chrome, .edge, .brave: return true
        case .safari, .arc: return false
        }
    }
}
