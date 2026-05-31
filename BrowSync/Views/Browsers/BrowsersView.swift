// BrowsersView.swift
// BrowSync — Tab 1: Browser detection and status

import SwiftUI

struct BrowsersView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Browsers"))
                        .font(.title2.bold())
                    Text(String(localized: "Browser detection and extension status"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await appState.refreshBrowsers() }
                } label: {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(appState.isScanning)
                .overlay {
                    if appState.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Browser list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(appState.browserInfos) { info in
                        BrowserRowView(info: info)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
