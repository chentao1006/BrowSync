import SwiftUI

struct RouterTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingRule: RouterRule?
    @State private var showingRuleEditor = false

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
            
            Divider()

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
                        Text("默认规则")
                            .fontWeight(.medium)
                        Spacer()
                        
                        Picker("", selection: $appState.fallbackBrowserId) {
                            ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                                Text(info.displayName).tag(String?(info.id.rawValue))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .padding(.vertical, 4)
                    
                    ForEach($appState.routerRules) { $rule in
                        RouterRuleRow(rule: $rule) {
                            editingRule = rule
                            showingRuleEditor = true
                        }
                    }
                    .onDelete { indexSet in
                        appState.routerRules.remove(atOffsets: indexSet)
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
                        appState.routerRules.append(newRule)
                        editingRule = newRule
                        showingRuleEditor = true
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
        .sheet(isPresented: $showingRuleEditor) {
            if let rule = editingRule {
                RuleEditorView(rule: rule) { updatedRule in
                    if let index = appState.routerRules.firstIndex(where: { $0.id == updatedRule.id }) {
                        appState.routerRules[index] = updatedRule
                    } else {
                        appState.routerRules.append(updatedRule)
                    }
                    showingRuleEditor = false
                    editingRule = nil
                } onCancel: {
                    showingRuleEditor = false
                    editingRule = nil
                }
                .environmentObject(appState)
            }
        }
        .onAppear {
            appState.checkDefaultBrowser()
        }
    }
}

struct RouterRuleRow: View {
    @EnvironmentObject var appState: AppState
    @Binding var rule: RouterRule
    var onEdit: () -> Void
    
    var body: some View {
        HStack {
            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
            
            VStack(alignment: .leading) {
                Text(rule.name)
                    .font(.headline)
                Text(rule.summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Spacer()
            
            if let targetId = rule.targetBrowserId {
                let displayName = appState.browserInfos.first(where: { $0.id.rawValue == targetId })?.displayName ?? targetId
                Text("使用 \(displayName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("走默认规则")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }
}
