// BrowserScanner.swift
// BrowSync — Detects installed browsers, versions, and extension status

import Foundation
import AppKit
import SafariServices
import os.log

@MainActor
final class BrowserScanner: ObservableObject {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "BrowserScanner")

    /// The extension ID used by the BrowSync Chromium extension (update in AppConfig)
    static var chromiumExtensionID: String { AppConfig.chromiumExtensionID }

    // MARK: - Scan All Browsers

    func scanAll(browsers: [Browser] = Browser.allCases) async -> [BrowserInfo] {
        var results: [BrowserInfo] = []
        for browser in browsers {
            let info = await scan(browser)
            results.append(info)
        }
        return results
    }

    func scan(_ browser: Browser) async -> BrowserInfo {
        var info = BrowserInfo.placeholder(for: browser)

        // 1. Check if installed
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier),
              FileManager.default.fileExists(atPath: appURL.path),
              !appURL.pathComponents.contains(".Trash") else {
            info.isInstalled = false
            info.extensionStatus = .notInstalled
            return info
        }

        info.isInstalled = true
        info.appURL = appURL
        info.version = extractVersion(from: appURL)

        if browser == .safari {
            info.extensionStatus = await checkSafariExtensionStatus()
        } else {
            // A sandboxed app cannot inspect another browser's profile or
            // extension database. Treating the container's empty profile as
            // Chrome/Firefox data produced false "Extension Required" and
            // "Extension Disabled" states. AppState promotes this state as
            // soon as the extension itself connects to the local daemon, and
            // remembers a prior successful connection for offline browsers.
            info.extensionStatus = .extensionRequired
        }

        // 3. Check if default
        if let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://apple.com")!) {
            if let defaultBundleId = Bundle(url: defaultURL)?.bundleIdentifier {
                info.isDefault = (defaultBundleId == browser.bundleIdentifier)
            }
        }

        return info
    }

    // MARK: - Version Extraction

    private func extractVersion(from appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard
            let plist = NSDictionary(contentsOf: plistURL),
            let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return version
    }

    // MARK: - Safari Extension Status

    private func checkSafariExtensionStatus() async -> ExtensionStatus {
        return await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(
                withIdentifier: AppConfig.safariExtensionBundleIdentifier
            ) { state, error in
                if error != nil {
                    continuation.resume(returning: .extensionRequired)
                    return
                }
                guard let state else {
                    continuation.resume(returning: .extensionRequired)
                    return
                }
                if state.isEnabled {
                    continuation.resume(returning: .waitingConnection)
                } else {
                    continuation.resume(returning: .extensionDisabled)
                }
            }
        }
    }

}
