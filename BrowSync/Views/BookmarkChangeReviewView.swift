// BookmarkChangeReviewView.swift
// BrowSync — Side-by-side review of a held Safari bookmark write

import SwiftUI
import AppKit

/// One node of a Safari bookmark tree annotated with what a pending write
/// would do to it. `before` trees can only contain removed/moved changes and
/// `after` trees only added/moved ones.
struct BookmarkReviewNode: Identifiable {
    enum Change {
        case unchanged, added, removed, moved, modified
    }

    let id: String
    let title: String
    let url: String?
    let isFolder: Bool
    let change: Change
    let children: [BookmarkReviewNode]
    /// This node or a descendant changes. Computed once here rather than per
    /// row, because a mass change can mark thousands of rows.
    let containsChange: Bool

    init(id: String, title: String, url: String?, isFolder: Bool, change: Change, children: [BookmarkReviewNode]) {
        self.id = id
        self.title = title
        self.url = url
        self.isFolder = isFolder
        self.change = change
        self.children = children
        self.containsChange = change != .unchanged || children.contains(where: \.containsChange)
    }
}

struct BookmarkChangePreview {
    let before: [BookmarkReviewNode]
    let after: [BookmarkReviewNode]
}

/// Where a held write would go. Every direction is reviewed the same way.
enum BookmarkReviewDestination {
    /// Into Safari, from `source`.
    case safari(source: String, keepUpdatesOtherBrowsers: Bool)
    /// Into another browser's bookmarks (computed by its extension).
    case browser(name: String)
}

struct BookmarkChangeReviewView: View {
    @EnvironmentObject var langBundle: LanguageBundle
    let destination: BookmarkReviewDestination
    let impact: SafariBookmarkService.WriteImpact
    let preview: BookmarkChangePreview
    let onApply: () -> Void
    let onKeep: () -> Void

    private var destinationName: String {
        switch destination {
        case .safari: return "Safari"
        case .browser(let name): return name
        }
    }

    private var summary: String {
        switch destination {
        case .safari(let source, _):
            return String(
                format: String(localized: "Syncing from %@ would remove %d, move %d and modify %d of %d existing Safari bookmarks. Nothing has been written yet.", bundle: langBundle.bundle),
                source, impact.removed, impact.moved, impact.modified, impact.total
            )
        case .browser(let name):
            return String(
                format: String(localized: "Syncing would remove %d, move %d and modify %d of %d existing bookmarks in %@. Nothing has been written yet.", bundle: langBundle.bundle),
                impact.removed, impact.moved, impact.modified, impact.total, name
            )
        }
    }

    private var keepFootnote: String {
        switch destination {
        case .safari(_, true):
            return String(localized: "Keeping Safari as is also brings the other browsers back to Safari's bookmarks.", bundle: langBundle.bundle)
        case .safari(_, false):
            return String(localized: "Keeping Safari as is pauses later bookmark changes from this browser until you resume them from the menu bar.", bundle: langBundle.bundle)
        case .browser(let name):
            return String(format: String(localized: "Keeping %@ as is pauses later bookmark changes to it until you resume them from the menu bar.", bundle: langBundle.bundle), name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Large Bookmark Change Blocked", bundle: langBundle.bundle))
                    .font(.title2.bold())
                Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                legendItem(.removed)
                legendItem(.moved)
                legendItem(.added)
                legendItem(.modified)
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 12) {
                pane(String(format: String(localized: "%@ Now", bundle: langBundle.bundle), destinationName), nodes: preview.before)
                pane(String(localized: "After Sync", bundle: langBundle.bundle), nodes: preview.after)
            }

            Text(keepFootnote)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                // No Escape shortcut: rejecting must be a deliberate click.
                // Closing the window instead leaves the change pending.
                Button(String(format: String(localized: "Keep %@ As Is", bundle: langBundle.bundle), destinationName), action: onKeep)
                Spacer()
                Button(String(localized: "Apply Changes", bundle: langBundle.bundle), role: .destructive, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 580)
    }

    private func pane(_ title: String, nodes: [BookmarkReviewNode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { BookmarkReviewNodeView(node: $0) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legendItem(_ change: BookmarkReviewNode.Change) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(change.tint.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(change.tint))
                .frame(width: 14, height: 14)
            Text(change.label(langBundle.bundle))
        }
    }
}

private struct BookmarkReviewNodeView: View {
    @EnvironmentObject var langBundle: LanguageBundle
    let node: BookmarkReviewNode
    @State private var isExpanded: Bool

    init(node: BookmarkReviewNode) {
        self.node = node
        // A moved folder is highlighted itself; its unchanged contents stay
        // collapsed so they do not bury the differences.
        _isExpanded = State(initialValue: node.children.contains(where: \.containsChange))
    }

    var body: some View {
        if node.isFolder && !node.children.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { BookmarkReviewNodeView(node: $0) }
            } label: {
                row
            }
        } else {
            row.padding(.leading, node.isFolder ? 0 : 18)
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "globe")
                .foregroundStyle(node.change == .unchanged ? Color.secondary : node.change.tint)
                .frame(width: 16)
            Text(node.title.isEmpty ? (node.url ?? "") : node.title)
                .strikethrough(node.change == .removed)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.change != .unchanged {
                Text(node.change.label(langBundle.bundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(node.change.tint)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(node.change == .unchanged ? Color.clear : node.change.tint.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help(node.url ?? node.title)
    }
}

private extension BookmarkReviewNode.Change {
    var tint: Color {
        switch self {
        case .unchanged: return .primary
        case .added: return .green
        case .removed: return .red
        case .moved: return .orange
        case .modified: return .blue
        }
    }

    func label(_ bundle: Bundle) -> String {
        switch self {
        case .unchanged: return ""
        case .added: return String(localized: "Added", bundle: bundle)
        case .removed: return String(localized: "Removed", bundle: bundle)
        case .moved: return String(localized: "Moved", bundle: bundle)
        case .modified: return String(localized: "Modified", bundle: bundle)
        }
    }
}

/// Hosts the review in its own window so the decision is made with both trees
/// in view, not from a notification button.
@MainActor
final class BookmarkChangeReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = BookmarkChangeReviewWindowController()

    private var window: NSWindow?
    private(set) var presentedClientId: String?

    /// `clientId` is the review's key: the source browser's ID for a write into
    /// Safari, "to:<ID>" for a write into that browser.
    func present(
        clientId: String,
        destination: BookmarkReviewDestination,
        impact: SafariBookmarkService.WriteImpact,
        preview: BookmarkChangePreview,
        activate: Bool = true,
        onApply: @escaping () -> Void,
        onKeep: @escaping () -> Void
    ) {
        let langBundle = LanguageBundle(language: AppState.shared.settingsService.general.language)
        let view = BookmarkChangeReviewView(
            destination: destination,
            impact: impact,
            preview: preview,
            // The decision runs after the button action has returned: it may
            // close this window or present the next review in it, which must
            // not tear down the hosting view while SwiftUI is still in the action.
            onApply: { [weak self] in
                self?.dismiss()
                DispatchQueue.main.async { onApply() }
            },
            onKeep: { [weak self] in
                self?.dismiss()
                DispatchQueue.main.async { onKeep() }
            }
        )
        .environmentObject(langBundle)

        let window = self.window ?? makeWindow()
        // Never "BrowSync": AppDelegate identifies the settings window by title.
        window.title = String(localized: "Review Bookmark Changes", bundle: langBundle.bundle)
        window.contentViewController = NSHostingController(rootView: view)
        if presentedClientId == nil { window.center() }
        presentedClientId = clientId
        // A refresh of an already open review must not steal focus again.
        guard activate else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
    }

    func dismiss(ifPresenting clientId: String) {
        guard presentedClientId == clientId else { return }
        dismiss()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing without choosing leaves the write pending; the notification
        // can reopen it. Drop the view so the trees and the pending payload
        // captured by its actions are not kept alive by the reused window.
        presentedClientId = nil
        DispatchQueue.main.async { [weak self] in
            // Only if no new review was presented in the meantime.
            guard let self, self.presentedClientId == nil else { return }
            self.window?.contentViewController = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Normal level: the user may want to look at Safari while deciding.
        window.delegate = self
        self.window = window
        return window
    }
}
