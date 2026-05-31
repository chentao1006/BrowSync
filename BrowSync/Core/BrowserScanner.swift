// BrowserScanner.swift
// BrowSync — Detects installed browsers, versions, and extension status

import Foundation
import AppKit
import SafariServices
import os.log

@MainActor
final class BrowserScanner: ObservableObject {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "BrowserScanner")

    /// The extension ID used by the BrowSync Chromium extension (update after publishing)
    static let chromiumExtensionID = "browsync-extension-placeholder"

    // MARK: - Scan All Browsers

    func scanAll() async -> [BrowserInfo] {
        var results: [BrowserInfo] = []
        for browser in Browser.allCases {
            let info = await scan(browser)
            results.append(info)
        }
        return results
    }

    func scan(_ browser: Browser) async -> BrowserInfo {
        var info = BrowserInfo.placeholder(for: browser)

        // 1. Check if installed
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
            info.isInstalled = false
            info.extensionStatus = .notInstalled
            return info
        }

        info.isInstalled = true
        info.appURL = appURL
        info.version = extractVersion(from: appURL)

        // 2. Check extension status
        if browser == .safari {
            info.extensionStatus = await checkSafariExtensionStatus()
        } else {
            info.extensionStatus = checkChromiumExtensionStatus(for: browser)
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
                withIdentifier: "com.ct106.browsync.extension"
            ) { state, error in
                if let error {
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

    // MARK: - Chromium Extension Status

    private func checkChromiumExtensionStatus(for browser: Browser) -> ExtensionStatus {
        guard let basePath = browser.extensionBasePath else { return .extensionRequired }

        let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let extensionsURL = libraryURL
            .appendingPathComponent(basePath)
            .appendingPathComponent("Default/Extensions")

        guard FileManager.default.fileExists(atPath: extensionsURL.path) else {
            return .extensionRequired
        }

        // Check if our extension ID folder exists
        let extensionFolder = extensionsURL.appendingPathComponent(Self.chromiumExtensionID)
        if FileManager.default.fileExists(atPath: extensionFolder.path) {
            // Check if enabled via Preferences (best-effort)
            return checkChromiumExtensionEnabled(for: browser)
        }

        // Also do a broader scan for any manifest containing our extension name
        if scanExtensionDirectory(extensionsURL) {
            return .waitingConnection
        }

        return .extensionRequired
    }

    private func checkChromiumExtensionEnabled(for browser: Browser) -> ExtensionStatus {
        guard let basePath = browser.extensionBasePath else { return .extensionDisabled }
        let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let prefsURL = libraryURL
            .appendingPathComponent(basePath)
            .appendingPathComponent("Default/Preferences")

        guard
            let data = try? Data(contentsOf: prefsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let extensions = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any],
            let extInfo = extensions[Self.chromiumExtensionID] as? [String: Any],
            let state = extInfo["state"] as? Int
        else {
            return .waitingConnection
        }
        // state == 1 means enabled in Chrome's Preferences JSON
        return state == 1 ? .waitingConnection : .extensionDisabled
    }

    /// Scan extension directory for a manifest.json containing BrowSync's extension name
    private func scanExtensionDirectory(_ directoryURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return false }

        for folder in contents {
            // Check version subfolders
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ) else { continue }
            for versionFolder in versions {
                let manifestURL = versionFolder.appendingPathComponent("manifest.json")
                guard
                    let data = try? Data(contentsOf: manifestURL),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let name = json["name"] as? String,
                    name.contains("BrowSync")
                else { continue }
                return true
            }
        }
        return false
    }
}
