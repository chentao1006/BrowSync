// AppConfig.swift
// BrowSync — Application Configuration

import Foundation

struct AppConfig {
    /// Chrome extension Web Store URL.
    static let chromiumExtensionWebStoreURL = "https://chrome.google.com/webstore/detail/nahmlhblgjnkkcmaiicngaepeepofpkh"
    
    /// The extension ID used by the BrowSync Chromium extension
    static let chromiumExtensionID = "nahmlhblgjnkkcmaiicngaepeepofpkh"

    /// The bundled Safari Web Extension identifier differs between distribution channels.
    static var safariExtensionBundleIdentifier: String {
        return "com.ct106.browsync.extension"
    }
}
