// AppConfig.swift
// BrowSync — Application Configuration

import AppKit
import Foundation

struct AppConfig {
    /// Mac App Store URL for the Store-distributed build.
    static let macAppStoreURL = "https://apps.apple.com/cn/app/id6784604835?mt=12"

    /// Legal links displayed alongside App Store subscription offers.
    static let privacyPolicyURL = URL(string: "https://browsync.ct106.com/privacy.html")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// StoreKit product ID for the one-time Professional unlock.
    static let proProductID = "com.ct106.browsync.pro"

    /// StoreKit product IDs for auto-renewable Professional subscriptions.
    /// Create both products in the same subscription group in App Store Connect.
    static let proMonthlySubscriptionProductID = "com.ct106.browsync.pro.monthly"
    static let proYearlySubscriptionProductID = "com.ct106.browsync.pro.yearly"

    static let proSubscriptionProductIDs: Set<String> = [
        proMonthlySubscriptionProductID,
        proYearlySubscriptionProductID
    ]

    static let proProductIDs: Set<String> = Set([proProductID])
        .union(proSubscriptionProductIDs)

    /// Chrome extension Web Store URL.
    static let chromiumExtensionWebStoreURL = "https://chrome.google.com/webstore/detail/nahmlhblgjnkkcmaiicngaepeepofpkh"

    /// The extension ID used by the BrowSync Chromium extension
    static let chromiumExtensionID = "nahmlhblgjnkkcmaiicngaepeepofpkh"

    /// Firefox Add-ons (AMO) URL.
    static let firefoxExtensionAMOURL = "https://addons.mozilla.org/zh-CN/firefox/addon/brow-sync/"

    /// Safari 16.4 introduced the optional-permission APIs used by the modern
    /// extension. Keep the existing identifier on that majority path so an
    /// update does not make those users re-enable the extension.
    static let safariModernExtensionBundleIdentifier = "com.ct106.browsync.extension"
    static let safariLegacyExtensionBundleIdentifier = "com.ct106.browsync.extension.legacy"

    /// The compatible extension identifier for the Safari installed on this Mac.
    static var safariExtensionBundleIdentifier: String {
        safariSupportsDynamicExtensionPermissions
            ? safariModernExtensionBundleIdentifier
            : safariLegacyExtensionBundleIdentifier
    }

    private static var safariSupportsDynamicExtensionPermissions: Bool {
        guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
              let safariBundle = Bundle(url: safariURL),
              let version = safariBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            // Safari is unavailable, or its version cannot be read. Prefer the
            // current extension; the scanner will only query it when Safari is installed.
            return true
        }

        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        let minor = parts.dropFirst().first ?? 0
        return major > 16 || (major == 16 && minor >= 4)
    }
}
