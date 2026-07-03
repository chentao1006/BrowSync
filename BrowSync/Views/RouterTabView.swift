import SwiftUI

struct RouterTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @State private var editingRule: RouterRule?
    @State private var installedApps: [InstalledAppInfo] = []
    @State private var ruleToDelete: RouterRule?
    @State private var showUpgradeAlert = false

    private var canAddRule: Bool {
        appState.purchaseService.isProUnlocked || appState.routerRules.count < ProLimits.freeRouterRuleCount
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with Master Switch
            HStack {
                Text(String(localized: "Link Router", bundle: langBundle.bundle))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Toggle(String(localized: "Enable Routing", bundle: langBundle.bundle), isOn: $appState.isRouterEnabled)
                    .toggleStyle(.switch)
            }
            .padding()
            
            // Default Browser Banner
            if !appState.isDefaultBrowser {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(String(localized: "Not default browser warning", bundle: langBundle.bundle))
                    Spacer()
                    Button(String(localized: "Set as Default", bundle: langBundle.bundle)) {
                        appState.promptSetDefaultBrowser()
                    }
                }
                .padding()
                .background(Color.yellow.opacity(0.1))
            }
            
            VStack(spacing: 0) {
                // Rules List
                List {
                    // Fallback rule at the top
                    HStack {
                        Image(systemName: "arrow.uturn.right.circle.fill")
                            .foregroundColor(.secondary)
                        Text(String(localized: "Default Browser", bundle: langBundle.bundle))
                            .fontWeight(.medium)
                        Spacer()
                        
                        Picker("", selection: $appState.fallbackBrowserId) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Label {
                                    Text(info.displayName)
                                } icon: {
                                    AppIconImage(appURL: info.appURL)
                                }
                                .tag(String?(info.id.rawValue))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .padding(.vertical, 4)
                    
                    if appState.routerRules.isEmpty {
                        VStack(spacing: 12) {
                            Spacer().frame(height: 40)
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(String(localized: "No Rules", bundle: langBundle.bundle))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text(String(localized: "Add rules to automatically route URLs to specific browsers based on domain, URL pattern, or source app.", bundle: langBundle.bundle))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            
                            Button(action: {
                                addRuleOrShowUpgrade()
                            }) {
                                HStack(spacing: 6) {
                                    Label(String(localized: "Add First Rule", bundle: langBundle.bundle), systemImage: "plus")
                                    if !canAddRule {
                                        ProBadge()
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.top, 12)
                            Spacer().frame(height: 40)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach($appState.routerRules) { $rule in
                            RouterRuleRow(rule: $rule, installedApps: installedApps) {
                                editingRule = rule
                            } onDelete: {
                                ruleToDelete = rule
                            }
                        }
                        .onDelete { indexSet in
                            if let firstIndex = indexSet.first {
                                ruleToDelete = appState.routerRules[firstIndex]
                            }
                        }
                        .onMove { indices, newOffset in
                            appState.routerRules.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                }
                .listStyle(.inset)
                
                if !appState.routerRules.isEmpty {
                    // Bottom Action Bar
                    HStack {
                        Button(action: {
                            addRuleOrShowUpgrade()
                        }) {
                            HStack(spacing: 6) {
                                Label(String(localized: "Add Rule", bundle: langBundle.bundle), systemImage: "plus")
                                if !canAddRule {
                                    ProBadge()
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding()
                }
            }
            .disabled(!appState.isRouterEnabled)
            
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule, initialInstalledApps: installedApps) { updatedRule in
                if let index = appState.routerRules.firstIndex(where: { $0.id == updatedRule.id }) {
                    appState.routerRules[index] = updatedRule
                } else {
                    guard canAddRule else {
                        showUpgradeAlert = true
                        return
                    }
                    appState.routerRules.append(updatedRule)
                }
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
            .environmentObject(appState)
            .environmentObject(langBundle)
        }
        .alert(String(localized: "Confirm delete router rule", bundle: langBundle.bundle), isPresented: Binding(
            get: { ruleToDelete != nil },
            set: { if !$0 { ruleToDelete = nil } }
        ), presenting: ruleToDelete) { rule in
            Button(String(localized: "Delete", bundle: langBundle.bundle), role: .destructive) {
                appState.routerRules.removeAll { $0.id == rule.id }
            }
            Button(String(localized: "Cancel", bundle: langBundle.bundle), role: .cancel) {}
        } message: { rule in
            Text(String(format: String(localized: "Delete router rule message", bundle: langBundle.bundle), rule.name))
        }
        .alert(String(localized: "Professional Required", bundle: langBundle.bundle), isPresented: $showUpgradeAlert) {
            Button(String(localized: "OK", bundle: langBundle.bundle), role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "Free version supports up to %d routing rules. Unlock Professional for unlimited rules.", bundle: langBundle.bundle), ProLimits.freeRouterRuleCount))
        }
        .onAppear {
            appState.checkDefaultBrowser()
            loadInstalledApps()
        }
    }

    private func addRuleOrShowUpgrade() {
        guard canAddRule else {
            showUpgradeAlert = true
            return
        }
        editingRule = RouterRule()
    }

    private func loadInstalledApps() {
        guard installedApps.isEmpty else { return }

        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let apps = await Task.detached(priority: .utility) {
                InstalledAppResolver.loadApplications()
            }.value
            installedApps = apps
        }
    }
}

struct RouterRuleRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @Binding var rule: RouterRule
    var installedApps: [InstalledAppInfo]
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        HStack {
            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
            
            Button(action: onEdit) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(rule.name)
                            .font(.headline)
                        conditionSummary
                    }
                    
                    Spacer()
                    
                    if let targetId = rule.targetBrowserId {
                        let targetInfo = appState.browserInfos.first(where: { $0.id.rawValue == targetId })
                        HStack(spacing: 6) {
                            AppIconImage(appURL: targetInfo?.appURL, size: 20)
                            Text(targetInfo?.displayName ?? targetId)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.right.circle.fill")
                                .foregroundStyle(.primary)
                            Text(String(localized: "Default (fallback)", bundle: langBundle.bundle))
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(isHovering ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var conditionSummary: some View {
        if rule.conditions.isEmpty {
            Text(String(localized: "No conditions", bundle: langBundle.bundle))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(rule.conditions.enumerated()), id: \.element.id) { index, condition in
                    if index > 0 {
                        Text(rule.logic == .and ? String(localized: "AND", bundle: langBundle.bundle) : String(localized: "OR", bundle: langBundle.bundle))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    conditionSummaryItem(condition)
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func conditionSummaryItem(_ condition: RuleCondition) -> some View {
        if condition.field == .sourceApp {
            let app = installedApps.first { $0.id == condition.value }
            AppIconImage(appURL: app?.url, size: 16)
                .help(app?.name ?? condition.value)
        } else {
            Text(condition.summaryText)
                .font(.caption)
                .foregroundColor(.secondary)
                .truncationMode(.tail)
        }
    }
}
