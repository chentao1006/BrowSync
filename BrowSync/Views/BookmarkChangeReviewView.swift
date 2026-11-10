// BookmarkChangeReviewView.swift
// BrowSync — Per-destination review of a held bookmark write

import SwiftUI
import AppKit

/// One node of a Safari bookmark tree annotated with what a pending write
/// would do to it. `before` trees can only contain removed/moved changes and
/// `after` trees only added/moved ones.
struct BookmarkReviewNode: Identifiable {
    enum Change: Hashable {
        case unchanged, added, removed, moved, reordered, modified
    }

    let id: String
    let title: String
    let url: String?
    let isFolder: Bool
    let change: Change
    let children: [BookmarkReviewNode]
    /// Explicit containing-folder path for flat, app-planned native changes.
    /// Safari previews use the nested tree and leave this nil.
    let containingPath: String?
    /// This node or a descendant changes. Computed once here rather than per
    /// row, because a mass change can mark thousands of rows.
    let containsChange: Bool

    init(id: String, title: String, url: String?, isFolder: Bool, change: Change, children: [BookmarkReviewNode], containingPath: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.isFolder = isFolder
        self.change = change
        self.children = children
        self.containingPath = containingPath
        self.containsChange = change != .unchanged || children.contains(where: \.containsChange)
    }
}

struct BookmarkChangePreview {
    let before: [BookmarkReviewNode]
    let after: [BookmarkReviewNode]
}

struct BookmarkReviewRoute: Identifiable {
    let id: String
    let source: String
    let target: String
    let impact: SafariBookmarkService.WriteImpact
    let preview: BookmarkChangePreview
    var conflicts: [BookmarkConflict] = []
    /// Set for aggregate sync groups, which are titled by their target only.
    var targetBrowser: Browser? = nil
    /// The group holding cross-browser conflicts (no header of its own).
    var isConflictGroup = false
}

private struct BookmarkChangeRow: Identifiable {
    let id: String
    let change: BookmarkReviewNode.Change
    let before: BookmarkReviewNode?
    let after: BookmarkReviewNode?
    let beforePath: String?
    let afterPath: String?

    var node: BookmarkReviewNode { after ?? before! }
}

struct BookmarkChangeReviewView: View {
    @EnvironmentObject var langBundle: LanguageBundle
    let reviewRoutes: [BookmarkReviewRoute]
    let onApplySelected: ([String: Set<String>], [String: [String: BookmarkConflictResolution]]) -> Void
    let onCancel: () -> Void
    /// When set, every row offers "Ignore" on hover.
    var onIgnoreRow: ((String, String) -> Void)? = nil
    var onIgnoreConflict: ((String) -> Void)? = nil
    @State private var selectedNodeIds: [String: Set<String>] = [:]
    @State private var conflictChoices: [String: [String: BookmarkConflictResolution]] = [:]
    @State private var hiddenRows: [String: Set<String>] = [:]
    @State private var hiddenConflicts: Set<String> = []
    @State private var hoveredItem: String?

    private func visibleRows(_ route: BookmarkReviewRoute) -> [BookmarkChangeRow] {
        let hidden = hiddenRows[route.id] ?? []
        return changeRows(for: route.preview).filter { !hidden.contains($0.id) }
    }

    private func visibleConflicts(_ route: BookmarkReviewRoute) -> [BookmarkConflict] {
        route.conflicts.filter { !hiddenConflicts.contains($0.id) }
    }

    private var visibleRoutes: [BookmarkReviewRoute] {
        reviewRoutes.filter { !visibleRows($0).isEmpty || !visibleConflicts($0).isEmpty }
    }

    private var summary: String {
        let impact = aggregateImpact
        return String(
            format: String(localized: "Across %d destinations, this sync would add %d, remove %d, move %d, reorder %d and modify %d bookmarks. Nothing has been written yet.", bundle: langBundle.bundle),
            visibleRoutes.filter { !$0.isConflictGroup }.count, impact.added, impact.removed, impact.moved, impact.reordered, impact.modified
        )
    }

    private var aggregateImpact: (added: Int, removed: Int, moved: Int, reordered: Int, modified: Int) {
        reviewRoutes.reduce((0, 0, 0, 0, 0)) { result, route in
            let counts = displayedCounts(for: route)
            return (result.0 + counts.added, result.1 + counts.removed, result.2 + counts.moved,
                    result.3 + counts.reordered, result.4 + counts.modified)
        }
    }

    private var allConflictsHaveChoices: Bool {
        reviewRoutes.allSatisfy { route in
            visibleConflicts(route).allSatisfy { conflict in
                conflictChoices[route.id]?[conflict.id] != nil
            }
        }
    }

    private var hasAnyDecision: Bool {
        // With every row ignored, applying simply closes this sync.
        selectedNodeIds.values.contains { !$0.isEmpty } || reviewRoutes.contains { !visibleConflicts($0).isEmpty }
            || visibleRoutes.isEmpty
    }

    private func displayedCounts(for route: BookmarkReviewRoute) -> (added: Int, removed: Int, moved: Int, reordered: Int, modified: Int) {
        visibleRows(route).reduce((0, 0, 0, 0, 0)) { result, row in
            switch row.change {
            case .added: return (result.0 + 1, result.1, result.2, result.3, result.4)
            case .removed: return (result.0, result.1 + 1, result.2, result.3, result.4)
            case .moved: return (result.0, result.1, result.2 + 1, result.3, result.4)
            case .reordered: return (result.0, result.1, result.2, result.3 + 1, result.4)
            case .modified: return (result.0, result.1, result.2, result.3, result.4 + 1)
            case .unchanged: return result
            }
        }
    }

    /// How many rows the review would actually show for this preview. Every
    /// caller that decides to open the window must use this, so a plan can
    /// never open an empty review.
    static func visibleRowCount(for preview: BookmarkChangePreview) -> Int {
        changeRows(for: preview).count
    }

    private func changeRows(for preview: BookmarkChangePreview) -> [BookmarkChangeRow] {
        Self.changeRows(for: preview)
    }

    private static func changeRows(for preview: BookmarkChangePreview) -> [BookmarkChangeRow] {
        let before = flattened(preview.before)
        let after = flattened(preview.after)
        let ids = Set(before.keys).union(after.keys)
        return ids.compactMap { id in
            let old = before[id]
            let new = after[id]
            // The "after" side describes additions, moves and edits; a
            // removal exists only "before". Comparing an absent optional
            // with `.unchanged` used to pick nil and drop every removal row.
            let afterChange = new.flatMap { $0.node.change == .unchanged ? nil : $0.node.change }
            let change = afterChange ?? old?.node.change
            guard let change, change != .unchanged,
                  // Sibling indexes are intentionally not synchronized. A
                  // legacy preview may still carry a reorder row, but it must
                  // never be shown as a selectable operation.
                  change != .reordered else { return nil }
            return BookmarkChangeRow(id: id, change: change, before: old?.node, after: new?.node, beforePath: old?.path, afterPath: new?.path)
        }.sorted { lhs, rhs in
            if lhs.change.order != rhs.change.order { return lhs.change.order < rhs.change.order }
            let leftPath = lhs.afterPath ?? lhs.beforePath ?? ""
            let rightPath = rhs.afterPath ?? rhs.beforePath ?? ""
            let pathOrder = leftPath.localizedStandardCompare(rightPath)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func flattened(_ roots: [BookmarkReviewNode]) -> [String: (node: BookmarkReviewNode, path: String)] {
        var result: [String: (node: BookmarkReviewNode, path: String)] = [:]
        func visit(_ node: BookmarkReviewNode, parents: [String]) {
            let title = node.title.isEmpty ? (node.url ?? "") : node.title
            // A row already displays the bookmark/folder title. Its path is
            // therefore only the containing folder path, always rooted with
            // "/"; including the node itself produced misleading paths such
            // as "…/GitHub → GitHub" for a move.
            let pathComponents = parents.filter { !$0.isEmpty }
            let nestedPath = "/" + pathComponents.joined(separator: "/")
            let path = node.containingPath ?? nestedPath
            var key = node.id
            if key.hasPrefix("before-") { key.removeFirst("before-".count) }
            if key.hasPrefix("after-") { key.removeFirst("after-".count) }
            result[key] = (node, path)
            let nextParents = node.isFolder && !title.isEmpty ? parents + [title] : parents
            node.children.forEach { visit($0, parents: nextParents) }
        }
        roots.forEach { visit($0, parents: []) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleRoutes) { route in
                        VStack(alignment: .leading, spacing: 8) {
                            if !route.isConflictGroup {
                                routeHeader(route)
                            }
                            ForEach([BookmarkReviewNode.Change.removed, .moved, .reordered, .modified, .added], id: \.self) { change in
                                let rows = visibleRows(route).filter { $0.change == change }
                                if !rows.isEmpty {
                                    HStack {
                                        Text(change.label(langBundle.bundle)).font(.subheadline.weight(.semibold))
                                        Text("\(rows.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(rows) { changeRow($0, routeId: route.id) }
                                }
                            }
                            ForEach(visibleConflicts(route)) { conflict in
                                conflictRow(conflict, routeId: route.id)
                            }
                        }
                        .padding(10)
                        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            HStack {
                // No Escape shortcut: rejecting must be a deliberate click.
                // Closing the window instead leaves the change pending.
                Button(String(localized: "Cancel This Sync", bundle: langBundle.bundle), action: onCancel)
                Spacer()
                Button(String(localized: "Apply Selected Changes", bundle: langBundle.bundle), role: aggregateImpact.removed + aggregateImpact.moved + aggregateImpact.reordered + aggregateImpact.modified > 0 ? .destructive : nil) {
                    onApplySelected(selectedNodeIds, conflictChoices)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(aggregateImpact.removed + aggregateImpact.moved + aggregateImpact.reordered + aggregateImpact.modified > 0 ? .red : .accentColor)
                    .disabled(!hasAnyDecision || !allConflictsHaveChoices)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { selectAllChanges() }
    }

    @ViewBuilder
    private func routeHeader(_ route: BookmarkReviewRoute) -> some View {
        HStack(spacing: 8) {
            if let target = route.targetBrowser {
                browserIcon(target, size: 20)
                Text(route.target).fontWeight(.semibold)
            } else {
                Text(route.source).fontWeight(.semibold)
                Image(systemName: "arrow.right")
                Text(route.target).fontWeight(.semibold)
            }
            Spacer()
            let counts = displayedCounts(for: route)
            Text("+\(counts.added)  −\(counts.removed)  ↔\(counts.moved)  ⇅\(counts.reordered)  ✎\(counts.modified)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func browserIcon(_ browser: Browser, size: CGFloat = 16) -> some View {
        if let url = browser.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityLabel(browser.displayName)
        } else {
            Image(systemName: browser.sfSymbol)
                .frame(width: size, height: size)
                .accessibilityLabel(browser.displayName)
        }
    }

    private func browserIcons(_ browsers: [Browser], size: CGFloat = 16) -> some View {
        HStack(spacing: 2) {
            ForEach(browsers, id: \.id) { browserIcon($0, size: size) }
        }
        .help(browsers.map(\.displayName).joined(separator: ", "))
    }

    @ViewBuilder
    private func ignoreButton(visible: Bool, action: @escaping () -> Void) -> some View {
        Button(String(localized: "Ignore", bundle: langBundle.bundle), action: action)
            .buttonStyle(.borderless)
            .font(.caption)
            .help(String(localized: "Don't offer this change again unless it changes.", bundle: langBundle.bundle))
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
    }

    private func selectAllChanges() {
        selectedNodeIds = Dictionary(uniqueKeysWithValues: reviewRoutes.map { route in
            (route.id, Set(changeRows(for: route.preview).map(\.id)))
        })
    }

    /// One line per change: path, title, URL. The change kind sits at the
    /// top right, "Ignore" at the bottom right (on hover).
    private func changeRow(_ item: BookmarkChangeRow, routeId: String) -> some View {
        let displayTitle: (BookmarkReviewNode) -> String = { $0.title.isEmpty ? ($0.url ?? "") : $0.title }
        let path: String? = {
            if item.change == .moved, let before = item.beforePath, let after = item.afterPath, before != after {
                return "\(before)  →  \(after)"
            }
            return item.afterPath ?? item.beforePath
        }()
        let title: String = {
            if item.change == .modified, let before = item.before, let after = item.after {
                return "\(displayTitle(before))  →  \(displayTitle(after))"
            }
            return displayTitle(item.node)
        }()
        return HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selectedNodeIds[routeId, default: []].contains(item.id) },
                set: { selected in
                    if selected { selectedNodeIds[routeId, default: []].insert(item.id) }
                    else { selectedNodeIds[routeId, default: []].remove(item.id) }
                }
            ))
            .labelsHidden()
            Image(systemName: item.node.isFolder ? "folder" : "bookmark")
                .foregroundStyle(item.change.tint)
                .frame(width: 18)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let path {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(title).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                if let url = item.node.url {
                    Text(url).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .help([path, title, item.node.url].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.change.label(langBundle.bundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.change.tint)
                if let onIgnoreRow {
                    ignoreButton(visible: hoveredItem == routeId + "|" + item.id) {
                        hiddenRows[routeId, default: []].insert(item.id)
                        selectedNodeIds[routeId, default: []].remove(item.id)
                        onIgnoreRow(routeId, item.id)
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(item.change.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredItem = routeId + "|" + item.id }
            else if hoveredItem == routeId + "|" + item.id { hoveredItem = nil }
        }
    }

    private func conflictRow(_ conflict: BookmarkConflict, routeId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(String(localized: "Bookmark Conflict", bundle: langBundle.bundle))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let onIgnoreConflict {
                    ignoreButton(visible: hoveredItem == "conflict|" + conflict.id) {
                        hiddenConflicts.insert(conflict.id)
                        conflictChoices[routeId]?.removeValue(forKey: conflict.id)
                        onIgnoreConflict(conflict.id)
                    }
                }
            }
            HStack(spacing: 8) {
                if !conflict.sourceBrowsers.isEmpty { browserIcons(conflict.sourceBrowsers) }
                Text(conflict.source.title).fontWeight(.medium)
                Text("↔").fontWeight(.medium)
                if !conflict.targetBrowsers.isEmpty { browserIcons(conflict.targetBrowsers) }
                Text(conflict.target.title).fontWeight(.medium)
            }
            let sourceURL = conflict.source.url.flatMap { $0 }
            let targetURL = conflict.target.url.flatMap { $0 }
            if let url = sourceURL ?? targetURL {
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                conflictChoiceButton(
                    String(format: String(localized: "Keep %@", bundle: langBundle.bundle), conflict.sourceLabel ?? conflict.source.sourceBrowser.displayName),
                    choice: .source, conflict: conflict, routeId: routeId, browsers: conflict.sourceBrowsers
                )
                conflictChoiceButton(
                    String(format: String(localized: "Keep %@", bundle: langBundle.bundle), conflict.targetLabel ?? conflict.target.sourceBrowser.displayName),
                    choice: .target, conflict: conflict, routeId: routeId, browsers: conflict.targetBrowsers
                )
                conflictChoiceButton(
                    String(localized: "Keep Both", bundle: langBundle.bundle),
                    choice: .both, conflict: conflict, routeId: routeId
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredItem = "conflict|" + conflict.id }
            else if hoveredItem == "conflict|" + conflict.id { hoveredItem = nil }
        }
    }

    private func conflictChoiceButton(
        _ title: String,
        choice: BookmarkConflictResolution,
        conflict: BookmarkConflict,
        routeId: String,
        browsers: [Browser] = []
    ) -> some View {
        let selected = conflictChoices[routeId]?[conflict.id] == choice
        return Button {
            conflictChoices[routeId, default: [:]][conflict.id] = choice
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .imageScale(.small)
                if !browsers.isEmpty { browserIcons(browsers, size: 14) }
                Text(title)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
            in: Capsule()
        )
        .contentShape(Capsule())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

private extension BookmarkReviewNode.Change {
    var order: Int {
        switch self { case .removed: 0; case .moved: 1; case .reordered: 2; case .modified: 3; case .added: 4; case .unchanged: 5 }
    }
    var tint: Color {
        switch self {
        case .unchanged: return .primary
        case .added: return .green
        case .removed: return .red
        case .moved, .reordered: return .orange
        case .modified: return .blue
        }
    }

    func label(_ bundle: Bundle) -> String {
        switch self {
        case .unchanged: return ""
        case .added: return String(localized: "Added", bundle: bundle)
        case .removed: return String(localized: "Removed", bundle: bundle)
        case .moved: return String(localized: "Moved", bundle: bundle)
        case .reordered: return String(localized: "Reordered", bundle: bundle)
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
        reviewRoutes: [BookmarkReviewRoute],
        activate: Bool = true,
        onApplySelected: @escaping ([String: Set<String>], [String: [String: BookmarkConflictResolution]]) -> Void,
        onCancel: @escaping () -> Void,
        onIgnoreRow: ((String, String) -> Void)? = nil,
        onIgnoreConflict: ((String) -> Void)? = nil
    ) {
        let langBundle = LanguageBundle(language: AppState.shared.settingsService.general.language)
        let view = BookmarkChangeReviewView(
            reviewRoutes: reviewRoutes,
            // The decision runs after the button action has returned: it may
            // close this window or present the next review in it, which must
            // not tear down the hosting view while SwiftUI is still in the action.
            onApplySelected: { [weak self] selection, conflicts in
                self?.dismiss()
                DispatchQueue.main.async { onApplySelected(selection, conflicts) }
            },
            onCancel: { [weak self] in
                self?.dismiss()
                DispatchQueue.main.async { onCancel() }
            },
            onIgnoreRow: onIgnoreRow,
            onIgnoreConflict: onIgnoreConflict
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
