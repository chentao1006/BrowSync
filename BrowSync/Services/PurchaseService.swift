// PurchaseService.swift
// BrowSync - Pro purchase state and unlock flow

import Foundation
import AppKit
#if APP_STORE
import StoreKit
#endif

enum ProFeature: String, CaseIterable, Identifiable {
    case advancedRules
    case unlimitedSync
    case iCloudSync
    case websiteRules
    case tabSharing

    var id: String { rawValue }

    var title: String.LocalizationValue {
        switch self {
        case .advancedRules: return "Advanced Rules"
        case .unlimitedSync: return "Unlimited Sync"
        case .iCloudSync: return "iCloud Sync"
        case .websiteRules: return "Site Sync Rules"
        case .tabSharing: return "Tab Sharing"
        }
    }

    var description: String.LocalizationValue {
        switch self {
        case .advancedRules:
            return "Create more powerful routing rules for daily browser workflows."
        case .unlimitedSync:
            return "Keep browser data, bookmarks, and state sync available without free-tier limits."
        case .iCloudSync:
            return "Synchronize settings, rules, and open tabs across your Macs using iCloud."
        case .websiteRules:
            return "Configure independent sync policies for unlimited websites."
        case .tabSharing:
            return "Share all open tabs between supported browsers through BrowSync extensions."
        }
    }

    var systemImage: String {
        switch self {
        case .advancedRules: return "slider.horizontal.3"
        case .unlimitedSync: return "arrow.triangle.2.circlepath"
        case .iCloudSync: return "icloud"
        case .websiteRules: return "globe.badge.chevron.backward"
        case .tabSharing: return "square.and.arrow.up.on.square"
        }
    }
}

enum ProLimits {
    static let freeRouterRuleCount = 3
    static let freeSyncBrowserCount = 2
    static let freeWebsiteRuleCount = 3

    static func limitedTabsForSharing(_ tabs: [BrowserTab], isProUnlocked: Bool) -> [BrowserTab] {
        guard !isProUnlocked else { return tabs }
        if let activeTab = tabs.first(where: { $0.isActive }) {
            return [activeTab]
        }
        return tabs.first.map { [$0] } ?? []
    }

    static func limitedWebsiteSettings(_ settings: [WebsiteSyncSetting], isProUnlocked: Bool) -> [WebsiteSyncSetting] {
        guard !isProUnlocked else { return settings }
        return Array(settings.prefix(freeWebsiteRuleCount))
    }
}

enum PurchaseChannel {
    case appStore
    case direct
}

@MainActor
final class PurchaseService: ObservableObject {
#if APP_STORE
    @Published private(set) var isProUnlocked = false
#elseif LOCAL_PRO_TEST
    @Published private(set) var isProUnlocked = true
#else
    @Published private(set) var isProUnlocked = false
#endif
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var statusMessage: String.LocalizationValue?

#if APP_STORE
    @Published private(set) var product: Product?
    private var transactionUpdatesTask: Task<Void, Never>?
#endif

    private var hasStarted = false

    var channel: PurchaseChannel {
#if APP_STORE
        return .appStore
#else
        return .direct
#endif
    }

    var isLimited: Bool {
        !isProUnlocked
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        Task {
            await refresh()
        }

#if APP_STORE
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try Self.verified(result)
                    await self.refreshEntitlements()
                    await transaction.finish()
                } catch {
                    await self.setStatus("Could not verify the purchase.")
                }
            }
        }
#endif
    }

    func canUse(_ feature: ProFeature) -> Bool {
        isProUnlocked
    }

    func refresh() async {
#if APP_STORE
        isLoading = true
        defer { isLoading = false }

        do {
            let products = try await Product.products(for: [AppConfig.proProductID])
            product = products.first
            await refreshEntitlements()
            if product == nil {
                statusMessage = "Professional purchase is not configured yet."
            }
        } catch {
            statusMessage = "Could not load Professional purchase."
            await refreshEntitlements()
        }
#elseif LOCAL_PRO_TEST
        isProUnlocked = true
        statusMessage = "Development build - Professional unlocked."
#else
        isProUnlocked = false
        statusMessage = nil
#endif
    }

    func purchasePro() async {
#if APP_STORE
        if product == nil {
            await refresh()
        }

        guard let product else {
            statusMessage = "Professional purchase is not configured yet."
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                await refreshEntitlements()
                await transaction.finish()
                statusMessage = isProUnlocked ? "BrowSync Professional is unlocked." : "Purchase completed, but Professional is not active yet."
            case .userCancelled:
                statusMessage = nil
            case .pending:
                statusMessage = "Purchase is pending approval."
            @unknown default:
                statusMessage = "Purchase could not be completed."
            }
        } catch {
            statusMessage = "Purchase could not be completed."
        }
#else
        openStoreVersion()
#endif
    }

    func restorePurchases() async {
#if APP_STORE
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = isProUnlocked ? "BrowSync Professional is unlocked." : "No Professional purchase was found."
        } catch {
            statusMessage = "Could not restore purchases."
        }
#else
        openStoreVersion()
#endif
    }

    func openStoreVersion() {
        guard let url = URL(string: AppConfig.macAppStoreURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func setStatus(_ message: String.LocalizationValue) {
        statusMessage = message
    }

#if APP_STORE
    private func refreshEntitlements() async {
        var hasPro = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.verified(result),
                  transaction.productID == AppConfig.proProductID,
                  transaction.revocationDate == nil else {
                continue
            }
            hasPro = true
            break
        }
        isProUnlocked = hasPro
    }

    nonisolated private static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw PurchaseError.failedVerification
        }
    }

    nonisolated private enum PurchaseError: Error {
        case failedVerification
    }
#endif
}
