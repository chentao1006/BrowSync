// ProTabView.swift
// BrowSync - Pro unlock and feature overview

import SwiftUI

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
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

                Button(String(localized: "Restore Purchases", bundle: langBundle.bundle)) {
                    Task {
                        await purchaseService.restorePurchases()
                    }
                }
                .disabled(purchaseService.isPurchasing || purchaseService.isLoading)
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

    private var purchaseButtonTitle: String {
#if APP_STORE
        if purchaseService.isProUnlocked {
            return String(localized: "Unlocked", bundle: langBundle.bundle)
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
            return String(localized: "Professional Unlocked", bundle: langBundle.bundle)
        } else {
            return String(localized: "Free", bundle: langBundle.bundle)
        }
    }
}
