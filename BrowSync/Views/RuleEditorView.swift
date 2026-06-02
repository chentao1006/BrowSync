import SwiftUI
import AppKit

struct RuleEditorView: View {
    @EnvironmentObject var appState: AppState
    @State var rule: RouterRule
    
    var onSave: (RouterRule) -> Void
    var onCancel: () -> Void
    
    // For listing apps
    @State private var installedApps: [InstalledApp] = []
    
    struct InstalledApp: Identifiable, Hashable {
        let id: String // Bundle ID
        let name: String
        let url: URL
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("编辑规则")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            Form {
                Section {
                    TextField("规则名称", text: $rule.name)
                    
                    Picker("目标浏览器", selection: $rule.targetBrowserId) {
                        Text("走默认规则").tag(String?.none)
                        Divider()
                        ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                            Text(info.displayName).tag(String?(info.id.rawValue))
                        }
                    }
                }
                
                Section(header: Text("匹配条件").font(.subheadline).foregroundColor(.secondary)) {
                    Picker("满足以下", selection: $rule.logic) {
                        ForEach(RuleConditionLogic.allCases) { logic in
                            Text(logic.localizedName).tag(logic)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 8)
                    
                    if rule.conditions.isEmpty {
                        Text("没有设置任何条件，此规则将不会生效。")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    
                    ForEach($rule.conditions) { $condition in
                        ConditionRow(condition: $condition, installedApps: installedApps) {
                            rule.conditions.removeAll { $0.id == condition.id }
                        }
                    }
                    
                    Button("添加条件") {
                        rule.conditions.append(RuleCondition())
                    }
                    .padding(.top, 4)
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // Footer
            HStack {
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    onSave(rule)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 500, height: 450)
        .onAppear {
            loadInstalledApps()
        }
    }
    
    private func loadInstalledApps() {
        Task.detached {
            let fm = FileManager.default
            let urls = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications")
            ]
            
            var apps: [InstalledApp] = []
            
            for url in urls {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isApplicationKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
                
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "app" {
                        if let bundle = Bundle(url: fileURL), let bundleId = bundle.bundleIdentifier {
                            // Skip background apps to avoid clutter
                            if let info = bundle.infoDictionary {
                                let isBackground = (info["LSBackgroundOnly"] as? Bool) == true || (info["LSBackgroundOnly"] as? String) == "1"
                                let isUIElement = (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1"
                                if isBackground || isUIElement {
                                    continue
                                }
                            }
                            let name = fileURL.deletingPathExtension().lastPathComponent
                            if !apps.contains(where: { $0.id == bundleId }) {
                                apps.append(InstalledApp(id: bundleId, name: name, url: fileURL))
                            }
                        }
                    }
                }
            }
            
            let sortedApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            await MainActor.run {
                self.installedApps = sortedApps
            }
        }
    }
}

struct ConditionRow: View {
    @Binding var condition: RuleCondition
    var installedApps: [RuleEditorView.InstalledApp]
    var onRemove: () -> Void
    
    var body: some View {
        HStack {
            Picker("", selection: $condition.field) {
                ForEach(RuleConditionField.allCases) { field in
                    Text(field.localizedName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: condition.field) { _, newField in
                if newField == .sourceApp {
                    if condition.operator != .equals && condition.operator != .notEquals {
                        condition.operator = .equals
                    }
                }
            }
            
            if condition.field == .timePeriod {
                // Time period editor
                DatePicker("", selection: Binding(
                    get: { condition.startTime ?? Date() },
                    set: { condition.startTime = $0 }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                
                Text("至")
                
                DatePicker("", selection: Binding(
                    get: { condition.endTime ?? Date().addingTimeInterval(3600) },
                    set: { condition.endTime = $0 }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                
            } else {
                Picker("", selection: $condition.operator) {
                    if condition.field == .sourceApp {
                        Text(RuleConditionOperator.equals.localizedName).tag(RuleConditionOperator.equals)
                        Text(RuleConditionOperator.notEquals.localizedName).tag(RuleConditionOperator.notEquals)
                    } else {
                        ForEach(RuleConditionOperator.allCases) { op in
                            Text(op.localizedName).tag(op)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                
                if condition.field == .sourceApp {
                    // App picker
                    Picker("", selection: $condition.value) {
                        Text("手动输入").tag("")
                        Divider()
                        ForEach(installedApps) { app in
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            }
                            .tag(app.id)
                        }
                    }
                    .labelsHidden()
                    
                    if !installedApps.contains(where: { $0.id == condition.value }) && !condition.value.isEmpty {
                        TextField("Bundle ID", text: $condition.value)
                    }
                } else {
                    TextField("值", text: $condition.value)
                }
            }
            
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
