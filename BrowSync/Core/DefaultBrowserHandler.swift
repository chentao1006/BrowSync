// DefaultBrowserHandler.swift
// BrowSync — Handles incoming http/https links as the default browser

import Foundation
import AppKit
import os.log

@MainActor
final class DefaultBrowserHandler {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "DefaultBrowserHandler")
    private let launcher = BrowserLauncher()
    var rulesEngine: RulesEngine?

    // MARK: - Default Browser Registration

    /// Check if BrowSync is currently the default browser for http/https
    var isDefaultBrowser: Bool {
        let handler = LSCopyDefaultHandlerForURLScheme("https" as CFString)?.takeRetainedValue() as String?
        return handler == Bundle.main.bundleIdentifier
    }

    /// Register BrowSync as the default browser
    func registerAsDefaultBrowser() {
        let bundleId = Bundle.main.bundleIdentifier! as CFString
        LSSetDefaultHandlerForURLScheme("http" as CFString, bundleId)
        LSSetDefaultHandlerForURLScheme("https" as CFString, bundleId)
        logger.info("Registered as default browser")
    }

    /// Restore Safari as the default browser
    func restoreDefaultBrowser() {
        LSSetDefaultHandlerForURLScheme("http" as CFString, "com.apple.Safari" as CFString)
        LSSetDefaultHandlerForURLScheme("https" as CFString, "com.apple.Safari" as CFString)
        logger.info("Restored Safari as default browser")
    }

    // MARK: - URL Handling

    /// Handle an incoming URL from the system (called from AppDelegate)
    func handle(url: URL, sourceAppBundleId: String? = nil) {
        logger.info("Handling URL: \(url.absoluteString) from \(sourceAppBundleId ?? "unknown")")

        // Determine target browser via rules engine
        let targetBrowser: Browser
        if let engine = rulesEngine {
            targetBrowser = engine.match(url: url, sourceApp: sourceAppBundleId)
        } else {
            targetBrowser = .safari
        }

        logger.info("Routing to: \(targetBrowser.rawValue)")
        launcher.open(url, in: targetBrowser)
    }
}
