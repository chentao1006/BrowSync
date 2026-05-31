// RulesView.swift
// BrowSync — Tab 2: URL routing rules management

import SwiftUI

struct RulesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddRule = false
    @State private var editingRule: BrowserRule? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Rules"))
                        .font(.title2.bold())
                    Text(String(localized: "Route URLs to specific browsers based on domain, pattern, or source app"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAddRule = true
                } label: {
                    Label(String(localized: "Add Rule"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            if appState.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingAddRule) {
            RuleEditView(rule: nil) { newRule in
                appState.settingsService.addRule(newRule)
                appState.rules = appState.settingsService.rules
            }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditView(rule: rule) { updated in
                appState.settingsService.updateRule(updated)
                appState.rules = appState.settingsService.rules
            }
        }
    }

    private var rulesList: some View {
        List {
            ForEach(appState.rules) { rule in
                RuleRowView(rule: rule) {
                    editingRule = rule
                } onToggle: { enabled in
                    var updated = rule
                    updated.enabled = enabled
                    appState.settingsService.updateRule(updated)
                    appState.rules = appState.settingsService.rules
                }
            }
            .onDelete { offsets in
                appState.settingsService.deleteRule(at: offsets)
                appState.rules = appState.settingsService.rules
            }
            .onMove { from, to in
                appState.settingsService.moveRule(from: from, to: to)
                appState.rules = appState.settingsService.rules
            }

            // Fixed catch-all rule
            RuleRowView(
                rule: .catchAll,
                isCatchAll: true,
                onEdit: nil,
                onToggle: nil
            )
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "No Rules"))
                .font(.title3.bold())
            Text(String(localized: "Add rules to automatically route URLs to specific browsers based on domain, URL pattern, or source app."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button {
                showingAddRule = true
            } label: {
                Label(String(localized: "Add First Rule"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Rule Row

struct RuleRowView: View {
    let rule: BrowserRule
    var isCatchAll: Bool = false
    let onEdit: (() -> Void)?
    let onToggle: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Enable toggle
            if !isCatchAll, let onToggle {
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.name.isEmpty ? String(localized: "Unnamed Rule") : rule.name)
                        .font(.headline)
                        .foregroundStyle(rule.enabled || isCatchAll ? .primary : .secondary)

                    if isCatchAll {
                        Text(String(localized: "Default"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                // Summary
                ruleSummary
            }

            Spacer()

            // Target browser
            HStack(spacing: 4) {
                Image(systemName: rule.targetBrowser.sfSymbol)
                    .font(.caption)
                Text(rule.targetBrowser.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.secondary)

            // Edit button
            if !isCatchAll, let onEdit {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled || isCatchAll ? 1.0 : 0.5)
    }

    @ViewBuilder
    private var ruleSummary: some View {
        let parts: [String] = [
            rule.domains.isEmpty ? nil : rule.domains.prefix(2).joined(separator: ", "),
            rule.urlPatterns.isEmpty ? nil : rule.urlPatterns.prefix(1).map { "url: \($0)" }.joined(),
            rule.sourceApps.isEmpty ? nil : rule.sourceApps.prefix(1).joined(),
        ].compactMap { $0 }

        if isCatchAll {
            Text(String(localized: "All other URLs"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if parts.isEmpty {
            Text(String(localized: "No conditions set"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
