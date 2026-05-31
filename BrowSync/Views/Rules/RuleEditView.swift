// RuleEditView.swift
// BrowSync — Add/Edit rule sheet

import SwiftUI

struct RuleEditView: View {
    @Environment(\.dismiss) var dismiss
    let originalRule: BrowserRule?
    let onSave: (BrowserRule) -> Void

    @State private var rule: BrowserRule
    @State private var domainInput: String = ""
    @State private var urlPatternInput: String = ""
    @State private var selectedSourceApps: Set<String> = []
    @State private var startTimeHour: Int = 9
    @State private var startTimeMinute: Int = 0
    @State private var endTimeHour: Int = 18
    @State private var endTimeMinute: Int = 0
    @State private var useTimeRange: Bool = false

    init(rule: BrowserRule?, onSave: @escaping (BrowserRule) -> Void) {
        self.originalRule = rule
        self.onSave = onSave
        _rule = State(initialValue: rule ?? BrowserRule())
        if let rule {
            _domainInput = State(initialValue: rule.domains.joined(separator: ", "))
            _urlPatternInput = State(initialValue: rule.urlPatterns.joined(separator: ", "))
            _selectedSourceApps = State(initialValue: Set(rule.sourceApps))
            _useTimeRange = State(initialValue: rule.timeRange != nil)
            if let tr = rule.timeRange {
                _startTimeHour = State(initialValue: tr.startMinutes / 60)
                _startTimeMinute = State(initialValue: tr.startMinutes % 60)
                _endTimeHour = State(initialValue: tr.endMinutes / 60)
                _endTimeMinute = State(initialValue: tr.endMinutes % 60)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Text(originalRule == nil ? String(localized: "New Rule") : String(localized: "Edit Rule"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "Save")) { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(rule.name.isEmpty)
            }
            .padding()

            Divider()

            Form {
                // Name
                Section(String(localized: "Name")) {
                    TextField(String(localized: "e.g. Work Docs"), text: $rule.name)
                }

                // Conditions
                Section(String(localized: "Conditions")) {
                    LabeledContent(String(localized: "Domains")) {
                        TextField(String(localized: "chatgpt.com, *.github.com"), text: $domainInput)
                            .textFieldStyle(.plain)
                    }
                    LabeledContent(String(localized: "URL Contains")) {
                        TextField(String(localized: "/docs/, ?ref=slack"), text: $urlPatternInput)
                            .textFieldStyle(.plain)
                    }
                }

                // Source apps
                Section(String(localized: "Source App")) {
                    ForEach(BrowserRule.knownSourceApps, id: \.bundleId) { app in
                        Toggle(app.displayName, isOn: Binding(
                            get: { selectedSourceApps.contains(app.bundleId) },
                            set: { on in
                                if on { selectedSourceApps.insert(app.bundleId) }
                                else { selectedSourceApps.remove(app.bundleId) }
                            }
                        ))
                    }
                }

                // Time range
                Section {
                    Toggle(String(localized: "Time Range"), isOn: $useTimeRange.animation())
                    if useTimeRange {
                        LabeledContent(String(localized: "From")) {
                            timePicker(hour: $startTimeHour, minute: $startTimeMinute)
                        }
                        LabeledContent(String(localized: "To")) {
                            timePicker(hour: $endTimeHour, minute: $endTimeMinute)
                        }
                    }
                }

                // Target browser
                Section(String(localized: "Open In")) {
                    Picker(String(localized: "Browser"), selection: $rule.targetBrowser) {
                        ForEach(Browser.allCases) { browser in
                            HStack {
                                Image(systemName: browser.sfSymbol)
                                Text(browser.displayName)
                            }
                            .tag(browser)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if rule.targetBrowser.supportsProfiles {
                        LabeledContent(String(localized: "Profile")) {
                            TextField(String(localized: "Default"), text: Binding(
                                get: { rule.profile ?? "" },
                                set: { rule.profile = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 620)
    }

    @ViewBuilder
    private func timePicker(hour: Binding<Int>, minute: Binding<Int>) -> some View {
        HStack {
            Picker("", selection: hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .frame(width: 60)
            .labelsHidden()

            Text(":")

            Picker("", selection: minute) {
                ForEach([0, 15, 30, 45], id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .frame(width: 60)
            .labelsHidden()
        }
        .pickerStyle(.menu)
    }

    private func save() {
        rule.domains = domainInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        rule.urlPatterns = urlPatternInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        rule.sourceApps = Array(selectedSourceApps)

        rule.timeRange = useTimeRange ? TimeRange(
            startMinutes: startTimeHour * 60 + startTimeMinute,
            endMinutes: endTimeHour * 60 + endTimeMinute
        ) : nil

        onSave(rule)
        dismiss()
    }
}
