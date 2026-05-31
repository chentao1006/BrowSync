// FocusManager.swift
// BrowSync — Focus mode data structures (Phase 1: data + UI only)

import Foundation
import SwiftUI

// MARK: - Focus Mode

enum FocusMode: String, CaseIterable, Codable, Identifiable, Hashable {
    case work = "work"
    case ai = "ai"
    case entertainment = "entertainment"
    case deepFocus = "deep_focus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .work: return String(localized: "Work")
        case .ai: return String(localized: "AI")
        case .entertainment: return String(localized: "Entertainment")
        case .deepFocus: return String(localized: "Deep Focus")
        }
    }

    var sfSymbol: String {
        switch self {
        case .work: return "briefcase"
        case .ai: return "sparkles"
        case .entertainment: return "tv"
        case .deepFocus: return "moon.stars"
        }
    }

    var accentColor: Color {
        switch self {
        case .work: return .blue
        case .ai: return .purple
        case .entertainment: return .orange
        case .deepFocus: return .indigo
        }
    }
}

// MARK: - Focus Profile

struct FocusProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var mode: FocusMode
    var name: String
    var preferredBrowser: Browser
    var ruleIds: [UUID] = []     // IDs of BrowserRules to activate
    var isActive: Bool = false

    static func defaultProfiles() -> [FocusProfile] {
        [
            FocusProfile(mode: .work, name: String(localized: "Work"), preferredBrowser: .chrome),
            FocusProfile(mode: .ai, name: String(localized: "AI"), preferredBrowser: .arc),
            FocusProfile(mode: .entertainment, name: String(localized: "Entertainment"), preferredBrowser: .safari),
            FocusProfile(mode: .deepFocus, name: String(localized: "Deep Focus"), preferredBrowser: .safari),
        ]
    }
}

// MARK: - Focus Manager

@MainActor
final class FocusManager: ObservableObject {
    @Published var profiles: [FocusProfile] = FocusProfile.defaultProfiles()
    @Published var activeMode: FocusMode? = nil

    // NOTE: Automatic focus switching is NOT implemented in MVP.
    // This is a placeholder for Phase 2.

    func activate(_ mode: FocusMode) {
        // Phase 2: integrate with macOS Focus API
        activeMode = mode
    }

    func deactivate() {
        activeMode = nil
    }

    func profile(for mode: FocusMode) -> FocusProfile? {
        profiles.first { $0.mode == mode }
    }
}
