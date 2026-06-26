import SwiftUI
import AppKit

struct InstalledAppInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        let key = url.path
        if let icon = icons[key] {
            return icon
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[key] = icon
        return icon
    }
}

struct AppIconImage: View {
    let appURL: URL?
    var size: CGFloat = 18
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(appURL?.path ?? "")-\(size)") {
            guard let appURL else {
                icon = nil
                return
            }
            icon = AppIconCache.icon(for: appURL)
        }
    }
}

enum InstalledAppResolver {
    static func loadApplications() -> [InstalledAppInfo] {
        let fm = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]

        var appsByBundleId: [String: InstalledAppInfo] = [:]

        for directory in directories {
            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in contents where fileURL.pathExtension == "app" {
                guard let bundle = Bundle(url: fileURL), let bundleId = bundle.bundleIdentifier else { continue }

                if let info = bundle.infoDictionary {
                    let isBackground = (info["LSBackgroundOnly"] as? Bool) == true || (info["LSBackgroundOnly"] as? String) == "1"
                    let isUIElement = (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1"
                    if isBackground || isUIElement {
                        continue
                    }
                }

                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? fileURL.deletingPathExtension().lastPathComponent

                appsByBundleId[bundleId] = InstalledAppInfo(id: bundleId, name: name, url: fileURL)
            }
        }

        return appsByBundleId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct RuleEditorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @State var rule: RouterRule
    
    var onSave: (RouterRule) -> Void
    var onCancel: () -> Void
    
    // For listing apps
    @State private var installedApps: [InstalledAppInfo] = []
    @State private var isLoadingApps = false

    init(
        rule: RouterRule,
        initialInstalledApps: [InstalledAppInfo] = [],
        onSave: @escaping (RouterRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _rule = State(initialValue: rule)
        _installedApps = State(initialValue: initialInstalledApps)
        self.onSave = onSave
        self.onCancel = onCancel
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(String(localized: rule.name == "New Rule" ? "New Rule Header" : "Edit Rule Header", bundle: langBundle.bundle))
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: langBundle.bundle), text: $rule.name)
                    
                    Picker(String(localized: "Target Browser", bundle: langBundle.bundle), selection: $rule.targetBrowserId) {
                        Text(String(localized: "Default Browser", bundle: langBundle.bundle)).tag(String?.none)
                        Divider()
                        ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
                            Label {
                                Text(info.displayName)
                            } icon: {
                                AppIconImage(appURL: info.appURL)
                            }
                            .tag(String?(info.id.rawValue))
                        }
                    }
                }
                
                Section(header: Text(String(localized: "Match Conditions", bundle: langBundle.bundle)).font(.subheadline).foregroundColor(.secondary)) {
                    Picker(String(localized: "Match Logic", bundle: langBundle.bundle), selection: $rule.logic) {
                        ForEach(RuleConditionLogic.allCases) { logic in
                            Text(String(localized: String.LocalizationValue(logic.displayName), bundle: langBundle.bundle)).tag(logic)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 8)
                    
                    if rule.conditions.isEmpty {
                        Text(String(localized: "No Conditions Message", bundle: langBundle.bundle))
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    if isLoadingApps {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Loading Apps", bundle: langBundle.bundle))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    ForEach($rule.conditions) { $condition in
                        ConditionRow(condition: $condition, installedApps: installedApps) {
                            rule.conditions.removeAll { $0.id == condition.id }
                        }
                    }
                    
                    Button(String(localized: "Add Condition", bundle: langBundle.bundle)) {
                        rule.conditions.append(RuleCondition())
                    }
                    .padding(.top, 4)
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // Footer
            HStack {
                Button(String(localized: "Cancel", bundle: langBundle.bundle)) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Save", bundle: langBundle.bundle)) {
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
        guard installedApps.isEmpty, !isLoadingApps else { return }
        isLoadingApps = true

        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let apps = await Task.detached(priority: .utility) {
                InstalledAppResolver.loadApplications()
            }.value
            self.installedApps = apps
            self.isLoadingApps = false
        }
    }
}

struct ConditionRow: View {
    @EnvironmentObject var langBundle: LanguageBundle
    @Binding var condition: RuleCondition
    var installedApps: [InstalledAppInfo]
    var onRemove: () -> Void
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack {
            Picker("", selection: $condition.field) {
                ForEach(RuleConditionField.allCases) { field in
                    Text(String(localized: String.LocalizationValue(field.displayName), bundle: langBundle.bundle)).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: condition.field) { newField in
                if newField == .sourceApp || newField == .scheme {
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
                
                Text(String(localized: "To Time", bundle: langBundle.bundle))
                
                DatePicker("", selection: Binding(
                    get: { condition.endTime ?? Date().addingTimeInterval(3600) },
                    set: { condition.endTime = $0 }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                
            } else {
                Picker("", selection: $condition.operator) {
                    if condition.field == .sourceApp || condition.field == .scheme {
                        Text(String(localized: String.LocalizationValue(RuleConditionOperator.equals.displayName), bundle: langBundle.bundle)).tag(RuleConditionOperator.equals)
                        Text(String(localized: String.LocalizationValue(RuleConditionOperator.notEquals.displayName), bundle: langBundle.bundle)).tag(RuleConditionOperator.notEquals)
                    } else {
                        ForEach(RuleConditionOperator.allCases) { op in
                            Text(String(localized: String.LocalizationValue(op.displayName), bundle: langBundle.bundle)).tag(op)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                
                if condition.field == .sourceApp {
                    // App picker
                    Picker("", selection: $condition.value) {
                        if condition.value.isEmpty {
                            Text(String(localized: "Select App", bundle: langBundle.bundle)).tag("")
                            Divider()
                        } else if !installedApps.contains(where: { $0.id == condition.value }) {
                            Text(condition.value).tag(condition.value)
                            Divider()
                        }
                        
                        ForEach(installedApps) { app in
                            Label {
                                Text(app.name)
                            } icon: {
                                AppIconImage(appURL: app.url)
                            }
                            .tag(app.id)
                        }
                    }
                    .labelsHidden()
                } else if condition.field == .scheme {
                    Picker("", selection: $condition.value) {
                        if condition.value.isEmpty {
                            Text(String(localized: "Select Protocol", bundle: langBundle.bundle)).tag("")
                            Divider()
                        } else if !["http", "https", "file"].contains(condition.value) {
                            Text(condition.value).tag(condition.value)
                            Divider()
                        }
                        Text("http").tag("http")
                        Text("https").tag("https")
                        Text("file").tag("file")
                    }
                    .labelsHidden()
                } else {
                    TextField("", text: $condition.value)
                        .labelsHidden()
                }
            }
            
            Spacer(minLength: 8)
            
            Button(action: { showingDeleteConfirmation = true }) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .alert(String(localized: "Confirm Delete Condition", bundle: langBundle.bundle), isPresented: $showingDeleteConfirmation) {
                Button(String(localized: "Delete Condition", bundle: langBundle.bundle), role: .destructive, action: onRemove)
                Button(String(localized: "Cancel", bundle: langBundle.bundle), role: .cancel) {}
            }
        }
        .padding(.vertical, 2)
    }
}
