import SwiftUI

struct RouterTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingRule: RouterRule?
    @State private var installedApps: [InstalledAppInfo] = []
    @State private var ruleToDelete: RouterRule?

    var body: some View {
        VStack(spacing: 0) {
            // Header with Master Switch
            HStack {
                Text("浏览器分流")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Toggle("启用分流", isOn: $appState.isRouterEnabled)
                    .toggleStyle(.switch)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            // Default Browser Banner
            if !appState.isDefaultBrowser {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("BrowSync 目前不是系统默认浏览器，分流功能无法完全生效。")
                    Spacer()
                    Button("设为默认") {
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
                        Text("默认浏览器")
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
                .listStyle(.inset)
                
                // Bottom Action Bar
                HStack {
                    Button(action: {
                        let newRule = RouterRule()
                        editingRule = newRule
                    }) {
                        Label("添加规则", systemImage: "plus")
                    }
                    Spacer()
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .disabled(!appState.isRouterEnabled)
            
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule, initialInstalledApps: installedApps) { updatedRule in
                if let index = appState.routerRules.firstIndex(where: { $0.id == updatedRule.id }) {
                    appState.routerRules[index] = updatedRule
                } else {
                    appState.routerRules.append(updatedRule)
                }
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
            .environmentObject(appState)
        }
        .alert("确定要删除此分流规则吗？", isPresented: Binding(
            get: { ruleToDelete != nil },
            set: { if !$0 { ruleToDelete = nil } }
        ), presenting: ruleToDelete) { rule in
            Button("删除", role: .destructive) {
                appState.routerRules.removeAll { $0.id == rule.id }
            }
            Button("取消", role: .cancel) {}
        } message: { rule in
            Text("删除分流规则 \"\(rule.name)\" 后将无法恢复。")
        }
        .onAppear {
            appState.checkDefaultBrowser()
            loadInstalledApps()
        }
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
                            AppIconImage(appURL: targetInfo?.appURL, size: 16)
                            Text(targetInfo?.displayName ?? targetId)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.right.circle")
                                .foregroundStyle(.secondary)
                            Text("默认")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
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
            Text("无条件")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(rule.conditions.enumerated()), id: \.element.id) { index, condition in
                    if index > 0 {
                        Text(rule.logic == .and ? "且" : "或")
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
