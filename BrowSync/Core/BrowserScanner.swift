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
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
            info.isInstalled = false
            info.extensionStatus = .notInstalled
            return info
        }

        info.isInstalled = true
        info.appURL = appURL
        info.version = extractVersion(from: appURL)

        if browser == .safari {
            info.extensionStatus = await checkSafariExtensionStatus()
        } else if browser == .firefox {
            info.extensionStatus = checkFirefoxExtensionStatus()
        } else {
            info.extensionStatus = checkChromiumExtensionStatus(for: browser)
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

    // MARK: - Chromium Extension Status

    private func checkChromiumExtensionStatus(for browser: Browser) -> ExtensionStatus {
        guard let basePath = browser.extensionBasePath else { return .extensionRequired }

        let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let browserURL = libraryURL.appendingPathComponent(basePath)
        
        var foundAnyDisabled = false

        // Scan all possible profile directories (Default, Profile 1, Profile 2, etc.)
        if let subdirs = try? FileManager.default.contentsOfDirectory(at: browserURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for subdir in subdirs {
                let prefsURL = subdir.appendingPathComponent("Preferences")
                if FileManager.default.fileExists(atPath: prefsURL.path) {
                    // Check the Preferences file which is the ultimate source of truth
                    if let data = try? Data(contentsOf: prefsURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let extensions = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any] {
                        
                        // Check if our official ID is present
                        if let extInfo = extensions[Self.chromiumExtensionID] as? [String: Any] {
                            let state = extInfo["state"] as? Int ?? 1
                            if state == 1 { return .waitingConnection }
                            foundAnyDisabled = true
                        }
                        
                        // Fallback: check if ANY unpacked extension has a path containing "browsync"
                        for (_, info) in extensions {
                            guard let extInfo = info as? [String: Any] else { continue }
                            let path = (extInfo["path"] as? String)?.lowercased() ?? ""
                            let manifest = extInfo["manifest"] as? [String: Any]
                            let name = (manifest?["name"] as? String)?.lowercased() ?? ""
                            
                            if path.contains("browsync") || name.contains("browsync") || name.contains("__msg_extname__") {
                                let state = extInfo["state"] as? Int ?? 1
                                if state == 1 { return .waitingConnection }
                                foundAnyDisabled = true
                            }
                        }
                    }
                }

                // If Preferences check fails, do a fallback folder scan
                let extensionsURL = subdir.appendingPathComponent("Extensions")
                if scanExtensionDirectory(extensionsURL) {
                    return .waitingConnection
                }
            }
        }

        return foundAnyDisabled ? .extensionDisabled : .extensionRequired
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
                    name.lowercased().contains("browsync") || name.lowercased().contains("__msg_extname__")
                else { continue }
                return true
            }
        }
        return false
    }

    // MARK: - Firefox Extension Status

    private func checkFirefoxExtensionStatus() -> ExtensionStatus {
        let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let firefoxURL = libraryURL.appendingPathComponent("Firefox/Profiles")
        
        var foundExtension = false
        
        if let subdirs = try? FileManager.default.contentsOfDirectory(at: firefoxURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for subdir in subdirs {
                let extensionsJsonURL = subdir.appendingPathComponent("extensions.json")
                if let data = try? Data(contentsOf: extensionsJsonURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let addons = json["addons"] as? [[String: Any]] {
                    
                    for addon in addons {
                        if let name = addon["name"] as? String,
                           let active = addon["active"] as? Bool {
                            if name.lowercased().contains("browsync") || name.lowercased().contains("__msg_extname__") {
                                if active {
                                    return .waitingConnection
                                } else {
                                    foundExtension = true
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return foundExtension ? .extensionDisabled : .extensionRequired
    }
}
