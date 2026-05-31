// BrowserRule.swift
// BrowSync — URL routing rule model

import Foundation

// MARK: - Time Range

struct TimeRange: Codable, Equatable {
    /// Minutes from midnight, e.g. 9*60 = 540 for 09:00
    var startMinutes: Int
    var endMinutes: Int

    static let workDay = TimeRange(startMinutes: 9 * 60, endMinutes: 18 * 60)

    var startFormatted: String { formatMinutes(startMinutes) }
    var endFormatted: String { formatMinutes(endMinutes) }

    private func formatMinutes(_ total: Int) -> String {
        let h = total / 60
        let m = total % 60
        return String(format: "%02d:%02d", h, m)
    }

    func isActive(at date: Date = Date()) -> Bool {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let current = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinutes <= endMinutes {
            return current >= startMinutes && current < endMinutes
        } else {
            // Crosses midnight
            return current >= startMinutes || current < endMinutes
        }
    }
}

// MARK: - Browser Rule

struct BrowserRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String = ""

    /// Domain patterns, e.g. "chatgpt.com", "*.github.com"
    var domains: [String] = []

    /// URL substring patterns, e.g. "/docs/", "?ref=slack"
    var urlPatterns: [String] = []

    /// Source application bundle IDs, e.g. "com.tinyspeck.slackmacgap"
    var sourceApps: [String] = []

    /// Optional time window when rule is active
    var timeRange: TimeRange? = nil

    /// Focus mode name this rule belongs to (nil = always active)
    var focusMode: String? = nil

    /// Target browser to open the URL in
    var targetBrowser: Browser = .safari

    /// Optional browser profile name
    var profile: String? = nil

    // MARK: - Well-Known Source Apps

    static let knownSourceApps: [(displayName: String, bundleId: String)] = [
        ("Slack", "com.tinyspeck.slackmacgap"),
        ("Mail", "com.apple.mail"),
        ("Discord", "com.hnc.Discord"),
        ("Raycast", "com.raycast.macos"),
        ("Terminal", "com.apple.Terminal"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("Notion", "notion.id"),
        ("Figma", "com.figma.Desktop"),
        ("Telegram", "ru.keepcoder.Telegram"),
    ]
}

// MARK: - Default Rules

extension BrowserRule {
    /// The catch-all rule that always lives at the bottom of the list
    static var catchAll: BrowserRule {
        var rule = BrowserRule()
        rule.name = String(localized: "All Others")
        rule.targetBrowser = .safari
        rule.enabled = true
        return rule
    }
}
