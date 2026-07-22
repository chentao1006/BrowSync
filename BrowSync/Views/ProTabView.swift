// ProTabView.swift
// BrowSync - Pro unlock and feature overview

import SwiftUI
import StoreKit

struct ProBadge: View {
    var body: some View {
#if APP_STORE
        Text("PRO")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
#endif
    }
}

struct ProTabView: View {
    @EnvironmentObject var langBundle: LanguageBundle
    @ObservedObject private var purchaseService = AppState.shared.purchaseService

    private let comparisonRows: [(String.LocalizationValue, String.LocalizationValue, String.LocalizationValue)] = [
        ("Routing Rules", "Up to 3 rules", "Unlimited rules"),
        ("Sync Browsers", "Up to 2 browsers", "Unlimited browsers"),
        ("Site Sync Rules", "Up to 3 websites", "Unlimited websites"),
        ("Tab Sharing", "Current active tab only", "All open tabs"),
        ("Automatic Sync", "Manual sync", "Real-time automatic sync"),
        ("iCloud Sync", "Not included", "Included")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "BrowSync Professional", bundle: langBundle.bundle))
                    .font(.title2.bold())
                Spacer()
#if APP_STORE
                restorePurchasesButton
#endif
                statusBadge
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text(String(localized: "One-time purchase", bundle: langBundle.bundle))
                                .font(.headline)
                        } icon: {
                            Image(systemName: "sparkles")
                        }

                        Text(String(localized: "Unlock BrowSync Professional once and keep the professional features available on your Mac.", bundle: langBundle.bundle))
                            .foregroundStyle(.secondary)

                        purchaseActions

#if APP_STORE
                        if purchaseService.activeProProductID == AppConfig.proProductID {
                            Text(String(format: String(localized: "Current purchase: %@", bundle: langBundle.bundle), String(localized: purchaseService.proEntitlementKind.title, bundle: langBundle.bundle)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
#endif
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Subscription", bundle: langBundle.bundle)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Choose monthly or yearly access to BrowSync Professional. Subscriptions renew automatically and can be cancelled anytime in your App Store account settings.", bundle: langBundle.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)

#if APP_STORE
                        if purchaseService.subscriptionProducts.isEmpty {
                            Text(String(localized: "Professional subscription is not configured yet.", bundle: langBundle.bundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(purchaseService.subscriptionProducts, id: \.id) { product in
                                subscriptionRow(product)
                            }

                            Button(String(localized: "Manage Subscriptions", bundle: langBundle.bundle)) {
                                purchaseService.openManageSubscriptions()
                            }
                            .font(.caption)
                        }
#else
                        Text(String(localized: "Subscriptions are available in the App Store version.", bundle: langBundle.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
#endif
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Feature Comparison", bundle: langBundle.bundle)) {
                    HStack {
                        Text(String(localized: "Feature", bundle: langBundle.bundle))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(localized: "Free", bundle: langBundle.bundle))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(localized: "Professional", bundle: langBundle.bundle))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.secondary)

                    ForEach(0..<comparisonRows.count, id: \.self) { index in
                        let row = comparisonRows[index]
                        HStack(alignment: .top) {
                            Text(String(localized: row.0, bundle: langBundle.bundle))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(localized: row.1, bundle: langBundle.bundle))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(localized: row.2, bundle: langBundle.bundle))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }

                Section(String(localized: "Included in Professional", bundle: langBundle.bundle)) {
                    ForEach(ProFeature.allCases) { feature in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: feature.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: feature.title, bundle: langBundle.bundle))
                                    .font(.headline)
                                Text(String(localized: feature.description, bundle: langBundle.bundle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                if let statusMessage = purchaseService.statusMessage {
                    Section {
                        Text(String(localized: statusMessage, bundle: langBundle.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await purchaseService.refresh()
        }
    }

    @ViewBuilder
    private var purchaseActions: some View {
        switch purchaseService.channel {
        case .appStore:
            HStack {
                Button(purchaseButtonTitle) {
                    Task {
                        await purchaseService.purchasePro()
                    }
                }
                .disabled(purchaseService.isProUnlocked || purchaseService.isPurchasing || purchaseService.isLoading)
            }

        case .direct:
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "This build also uses the free limits. To unlock Professional, install the App Store version and purchase Professional there.", bundle: langBundle.bundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(String(localized: "Open App Store Version", bundle: langBundle.bundle)) {
                    purchaseService.openStoreVersion()
                }
            }
        }
    }

#if APP_STORE
    private var restorePurchasesButton: some View {
        Button(String(localized: "Restore Purchases", bundle: langBundle.bundle)) {
            Task {
                await purchaseService.restorePurchases()
            }
        }
        .font(.caption)
        .controlSize(.small)
        .disabled(purchaseService.isPurchasing || purchaseService.isLoading)
    }
#endif

    private var purchaseButtonTitle: String {
#if APP_STORE
        if purchaseService.activeProProductID == AppConfig.proProductID {
            return String(localized: "Current Purchase", bundle: langBundle.bundle)
        }
        if purchaseService.isPurchasing {
            return String(localized: "Purchasing...", bundle: langBundle.bundle)
        }
        if let product = purchaseService.product {
            return String(format: String(localized: "Unlock Professional - %@", bundle: langBundle.bundle), product.displayPrice)
        }
        return String(localized: "Unlock Professional", bundle: langBundle.bundle)
#else
        return String(localized: "Open App Store Version", bundle: langBundle.bundle)
#endif
    }

#if APP_STORE
    private func subscriptionRow(_ product: Product) -> some View {
        let isCurrentPlan = purchaseService.activeProProductID == product.id

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(product.displayName)
                        .font(.headline)

                    if isCurrentPlan {
                        Text(String(localized: "Current Plan", bundle: langBundle.bundle))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isCurrentPlan ? String(localized: "Current Plan", bundle: langBundle.bundle) : String(format: String(localized: "Subscribe - %@", bundle: langBundle.bundle), product.displayPrice)) {
                Task {
                    await purchaseService.purchase(product)
                }
            }
            .disabled(purchaseService.isProUnlocked || purchaseService.isPurchasing || purchaseService.isLoading)
        }
    }
#endif

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(purchaseService.isProUnlocked ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
            .foregroundStyle(purchaseService.isProUnlocked ? .green : .secondary)
            .clipShape(Capsule())
    }

    private var statusTitle: String {
        if purchaseService.isProUnlocked {
            return String(localized: purchaseService.proEntitlementKind.title, bundle: langBundle.bundle)
        } else {
            return String(localized: "Free", bundle: langBundle.bundle)
        }
    }
}
