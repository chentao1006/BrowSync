// AppConfig.swift
// BrowSync — Application Configuration

import Foundation

struct AppConfig {
    /// Mac App Store URL for the Store-distributed build.
    static let macAppStoreURL = "https://apps.apple.com/cn/app/id6784604835?mt=12"

    /// Placeholder StoreKit product ID for the one-time Pro unlock.
    static let proProductID = "com.ct106.browsync.pro"

    /// Chrome extension Web Store URL.
    static let chromiumExtensionWebStoreURL = "https://chrome.google.com/webstore/detail/nahmlhblgjnkkcmaiicngaepeepofpkh"
    
    /// The extension ID used by the BrowSync Chromium extension
    static let chromiumExtensionID = "nahmlhblgjnkkcmaiicngaepeepofpkh"

    /// The bundled Safari Web Extension identifier differs between distribution channels.
    static var safariExtensionBundleIdentifier: String {
        return "com.ct106.browsync.extension"
    }
}
