import Foundation

private struct TestFailure: Error, CustomStringConvertible { let description: String }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}

private func bookmark(_ id: String, _ title: String, parent: String?, folder: Bool = false, browser: Browser = .edge) -> Bookmark {
    Bookmark(id: id, title: title, url: folder ? nil : "https://example.com/\(id)", parentId: parent,
             isFolder: folder, sortIndex: 0, inBookmarksBar: parent == "1", dateAdded: nil, sourceBrowser: browser)
}

@main
private enum BookmarkRootMappingTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("root-to-root keeps system identity", testRootToRootKeepsSystemIdentity),
            ("selected bar-to-root flattens contents", testSelectedBookmarksBarToRoot),
            ("root-to-folder creates portable wrappers", testRootToSpecificFolder),
            ("Safari wrapper preserves Favorites identity", testSafariRootWrapper),
            ("empty Safari Favorites still wraps", testEmptySafariFavorites),
            ("folder-to-folder creates no system wrappers", testSelectedFolderToSelectedFolder),
            ("duplicate selected folder is refused", testDuplicateSelectedFolderIsRefused),
            ("bookmark writes obey OFF and one-way source", testBookmarkWritePolicy),
            ("safe mode defaults and migration preserve hard write rules", testSafeModeMigration),
            ("native app plans browser mutations", testNativeAppPlanner),
            ("native planner maps Safari system roots without creating folders", testNativePlannerMapsSystemRoots),
            ("same-slot bookmark differences require a conflict choice", testNativePlannerDetectsBookmarkConflict),
            ("native app refuses ambiguous target identity", testNativePlannerRefusesAmbiguity),
            ("native app preserves nodes outside selected scope", testNativePlannerPreservesOutsideScope),
            ("native app refuses mapped identity outside selected scope", testNativePlannerRefusesMappedOutsideScope),
            ("native app plans mapped deletions without escaping scope", testNativeRemovalPlan),
            ("recently deleted restore accepts existing parent", testRestoreAcceptsExistingParent),
            ("snapshot diff identifies deletion", testSnapshotDiffDeletion),
            ("snapshot diff distinguishes move and reorder", testSnapshotDiffMoveAndReorder),
            ("snapshot delta payload includes parent chain", testSnapshotDeltaPayloadIncludesParents),
            ("stable browser divergence becomes a conflict without a write", testStableSnapshotConflict),
            ("aggregate plan keeps every source for one target under one token", testAggregatePlanKeepsEverySource),
            ("aggregate conflict is shared across routes and resolved everywhere", testAggregateConflictResolution),
            ("aggregate keep-both creates the missing version only", testAggregateConflictKeepBoth),
            ("unselected planned folder drops dependent operations", testAggregatePruneDependencies),
            ("baseline keeps unhandled changes detectable", testBaselineRevertsUnhandledChanges),
            ("an unchanged node reported under a new ID is not a change", testIdentityDriftIsNotAChange),
            ("reconciliation recovers a missed addition", testReconcileMissedAddition),
            ("reconciliation propagates a newer missed deletion and keeps a newer re-add", testReconcileMissedDeletion),
            ("reconciliation never guesses from pending or out-of-scope bookmarks", testReconcileSkipsAmbiguous),
            ("edits made around a write stay detectable", testUnexplainedChangesSurviveWrite),
            ("an ignored change and its dependants are left out until the change differs", testIgnoredChangesAreFiltered),
            ("an ignored conflict does not block the other choices", testIgnoredConflictDoesNotBlock),
            ("Safari plan writes inside the selected folder and nowhere else", testSafariPlanStaysInScope),
            ("Safari executor edits in place and refuses out-of-scope or invalid operations", testSafariExecutorRefusals),
            ("Safari context refuses missing or duplicate folders and binds the token to the bytes", testSafariContextBinding),
            ("Safari maintenance runs only for an authorized whole-library sync", testSafariMaintenancePolicy),
            ("incremental restore only adds and never overwrites", testIncrementalRestoreOnlyAdds),
            ("replace restore changes only the selected folder", testReplaceRestoreStaysInFolder),
            ("restore payload drops archived browser roots", testRestorePayloadDropsRoots),
            ("restore scope follows the browser's sync folder", testRestoreScopeFollowsSyncFolder),
            ("folder backups keep their ancestor chain and stay restorable", testFolderBackupKeepsAncestors),
            ("Firefox root archives restore into native roots, never under the tree root", testFirefoxArchiveRoots),
            ("planner refuses operations into a parent outside the target tree", testPlannerRefusesUnknownParent),
            ("extension restores ignore foreign syncIdMap entries", testRestoreIgnoresForeignIdMap),
            ("incremental restore still adds a bookmark whose title exists elsewhere", testIncrementalRestoreSameTitleElsewhere),
            ("a native tree must be bound to exactly the requested folder", testContextScopeBinding)
        ]
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                print("FAIL: \(name): \(error)")
                throw error
            }
        }
        print("PASS: \(tests.count) bookmark root mapping tests")
    }

    private static func testRootToRootKeepsSystemIdentity() throws {
        let source = [bookmark("bar-item", "Bar Item", parent: "1"), bookmark("other-item", "Other Item", parent: "2")]
        let result = try unwrap(BookmarkTreeMerger.extractExistingSubtreeAsRoot(sourceTree: source, folderPath: nil), "root extraction failed")
        try expect(result == source, "root-to-root changed the source tree")
        try expect(result.first { $0.id == "bar-item" }?.parentId == "1", "bookmarks bar identity was lost")
        try expect(result.first { $0.id == "other-item" }?.parentId == "2", "other bookmarks identity was lost")
        try expect(!result.contains { $0.id == BookmarkFolderPath.rootBar }, "root-to-root created a named wrapper")
    }

    private static func testSelectedBookmarksBarToRoot() throws {
        let source = [
            bookmark("1", "Bookmarks Bar", parent: "0", folder: true),
            bookmark("bar-folder", "Work", parent: "1", folder: true),
            bookmark("nested", "Nested", parent: "bar-folder"),
            bookmark("other-item", "Other", parent: "2")
        ]
        let result = try unwrap(BookmarkTreeMerger.extractExistingSubtreeAsRoot(
            sourceTree: source, folderPath: BookmarkFolderPath.rootBar, portableParentId: "2"
        ), "selected bookmarks bar was not found")
        try expect(Set(result.map(\.id)) == ["bar-folder", "nested"], "folder shell or unrelated roots leaked into payload")
        try expect(result.first { $0.id == "bar-folder" }?.parentId == "2", "contents were not flattened to target root")
        try expect(result.first { $0.id == "nested" }?.parentId == "bar-folder", "nested hierarchy changed")
    }

    private static func testRootToSpecificFolder() throws {
        let source = [
            bookmark("bar-item", "Bar Item", parent: "1"),
            bookmark("other-item", "Other Item", parent: "2"),
            bookmark("mobile-item", "Mobile Item", parent: "3")
        ]
        let wrapped = BookmarkTreeMerger.wrappingSystemRootsForNonRootTarget(sourceTree: source, sourceBrowser: .edge)
        let target = [bookmark("target", "Destination", parent: "2", folder: true, browser: .safari)]
        let merged = try unwrap(BookmarkTreeMerger.replaceExistingFolderContents(
            sourceTree: wrapped, targetTree: target, targetFolderPath: "Destination"
        ), "target folder was not found")
        try expect(merged.first { $0.id == BookmarkFolderPath.rootBar }?.parentId == "target", "bar wrapper was not placed in target")
        try expect(merged.first { $0.id == BookmarkFolderPath.rootOther }?.parentId == "target", "other wrapper was not placed in target")
        try expect(merged.first { $0.id == BookmarkFolderPath.rootMobile }?.parentId == "target", "mobile wrapper was not placed in target")
        try expect(merged.first { $0.id == "bar-item" }?.parentId == BookmarkFolderPath.rootBar, "bar child was detached")
        try expect(merged.first { $0.id == "other-item" }?.parentId == BookmarkFolderPath.rootOther, "other child was detached")
        try expect(merged.first { $0.id == "mobile-item" }?.parentId == BookmarkFolderPath.rootMobile, "mobile child was detached")
    }

    private static func testSafariRootWrapper() throws {
        let source = [
            bookmark("1", "个人收藏", parent: "0", folder: true, browser: .safari),
            bookmark("favorite", "Favorite", parent: "1", browser: .safari)
        ]
        let result = BookmarkTreeMerger.wrappingSystemRootsForNonRootTarget(sourceTree: source, sourceBrowser: .safari)
        try expect(!result.contains { $0.id == "1" }, "native Safari root leaked into ordinary target")
        try expect(result.first { $0.id == BookmarkFolderPath.rootFavorites }?.title == "个人收藏", "Favorites title was not preserved")
        try expect(result.first { $0.id == "favorite" }?.parentId == BookmarkFolderPath.rootFavorites, "favorite was detached")
    }

    private static func testEmptySafariFavorites() throws {
        let source = [bookmark("1", "Favorites", parent: "0", folder: true, browser: .safari)]
        let result = BookmarkTreeMerger.wrappingSystemRootsForNonRootTarget(sourceTree: source, sourceBrowser: .safari)
        try expect(result.count == 1, "empty native root produced unexpected nodes")
        try expect(result[0].id == BookmarkFolderPath.rootFavorites, "empty Favorites did not become a wrapper")
        try expect(result[0].parentId == "2", "empty Favorites wrapper is not portable")
    }

    private static func testSelectedFolderToSelectedFolder() throws {
        let selected = [bookmark("source", "Source", parent: "1", folder: true), bookmark("child", "Child", parent: "source")]
        let flattened = try unwrap(BookmarkTreeMerger.extractExistingSubtreeAsRoot(
            sourceTree: selected, folderPath: "Source", portableParentId: "2"
        ), "source folder was not found")
        let target = [bookmark("target", "Target", parent: "2", folder: true, browser: .safari)]
        let merged = try unwrap(BookmarkTreeMerger.replaceExistingFolderContents(
            sourceTree: flattened, targetTree: target, targetFolderPath: "Target"
        ), "target folder was not found")
        try expect(merged.first { $0.id == "child" }?.parentId == "target", "content did not enter target folder")
        try expect(!merged.contains { $0.id == BookmarkFolderPath.rootBar }, "folder-to-folder created a system wrapper")
        try expect(!merged.contains { $0.id == "source" }, "source folder shell leaked into target")
    }

    private static func testDuplicateSelectedFolderIsRefused() throws {
        let tree = [
            bookmark("a", "Selected", parent: "2", folder: true),
            bookmark("b", "Selected", parent: "2", folder: true),
            bookmark("child-a", "A", parent: "a"),
            bookmark("child-b", "B", parent: "b")
        ]
        try expect(
            BookmarkTreeMerger.extractExistingSubtreeAsRoot(sourceTree: tree, folderPath: "Selected") == nil,
            "ambiguous same-parent folders selected the first match"
        )
    }

    private static func testBookmarkWritePolicy() throws {
        var settings = SyncSettings()
        settings.bookmarkParticipatingBrowsers = Set(Browser.allCases)
        try expect(!BookmarkWritePolicy.allowsWrite(to: .safari, settings: settings), "OFF allowed a Safari write")
        try expect(!BookmarkWritePolicy.allowsWrite(to: .chrome, settings: settings), "OFF allowed a Chrome write")
        try expect(!BookmarkWritePolicy.allowsWrite(to: .chrome, settings: settings, explicitRestore: true),
                   "OFF allowed an explicit restore")

        settings.enabledCategories.insert(.bookmarks)
        settings.bookmarkSyncStrategy = .oneWay
        for source in Browser.allCases {
            settings.bookmarkSourceBrowser = source
            for target in Browser.allCases {
                let expected = target != source
                try expect(
                    BookmarkWritePolicy.allowsWrite(to: target, settings: settings) == expected,
                    "one-way policy was wrong for source \(source.rawValue), target \(target.rawValue)"
                )
                try expect(BookmarkWritePolicy.allowsWrite(to: target, settings: settings, explicitRestore: true),
                           "explicit restore was refused for \(target.rawValue)")
            }
        }
    }

    private static func testSafeModeMigration() throws {
        try expect(SyncSettings().bookmarkSafeMode, "new installs did not default bookmark Safe Mode to enabled")

        let legacy = try JSONDecoder().decode(SyncSettings.self, from: Data("{}".utf8))
        try expect(legacy.bookmarkSafeMode, "existing settings without Safe Mode did not migrate to enabled")

        var optedOut = SyncSettings()
        optedOut.bookmarkSafeMode = false
        let decoded = try JSONDecoder().decode(SyncSettings.self, from: JSONEncoder().encode(optedOut))
        try expect(!decoded.bookmarkSafeMode, "explicit Safe Mode preference did not persist")
        try expect(!BookmarkWritePolicy.allowsWrite(to: .firefox, settings: decoded),
                   "disabling Safe Mode weakened the final bookmark-sync OFF rule")
    }

    private static func testNativeAppPlanner() throws {
        let target = [
            bookmark("bar", "Bookmarks Bar", parent: "root", folder: true, browser: .chrome),
            bookmark("keep", "Keep", parent: "bar", browser: .chrome),
            bookmark("remove", "Remove", parent: "bar", browser: .chrome)
        ]
        let desired = [
            Bookmark(id: "source-keep", title: "Keep", url: "https://example.com/keep", parentId: "1", isFolder: false,
                     sortIndex: 0, inBookmarksBar: true, dateAdded: nil, sourceBrowser: .safari),
            bookmark("source-new", "New", parent: "1", browser: .safari)
        ]
        let context = BookmarkNativeTreeContext(
            inputToken: "tree-v1", browser: .chrome, nodes: target,
            rootIds: ["1": "bar"], sourceToNativeIds: ["source-keep": "keep"], scopeRootId: nil
        )
        let plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: true)
        try expect(plan.inputToken == "tree-v1", "planner lost the extension input token")
        try expect(plan.operations.contains { $0.kind == .create && $0.title == "New" }, "missing bookmark was not planned as a create")
        try expect(plan.operations.contains { $0.kind == .removeTree && $0.id == "remove" }, "unmatched target bookmark was not planned for removal")
        try expect(!plan.operations.contains { $0.kind == .removeTree && $0.id == "keep" }, "mapped bookmark was incorrectly removed")
        try expect(plan.impact.added == 1 && plan.impact.removed == 1, "app impact summary is incorrect")
    }

    private static func testNativePlannerRefusesAmbiguity() throws {
        let target = [
            bookmark("bar", "Bookmarks Bar", parent: "root", folder: true, browser: .chrome),
            bookmark("a", "Duplicate", parent: "bar", folder: true, browser: .chrome),
            bookmark("b", "Duplicate", parent: "bar", folder: true, browser: .chrome)
        ]
        let desired = [bookmark("source", "Duplicate", parent: "1", folder: true, browser: .safari)]
        let context = BookmarkNativeTreeContext(inputToken: "tree-v1", browser: .chrome, nodes: target,
                                                rootIds: ["1": "bar"], sourceToNativeIds: [:], scopeRootId: nil)
        let plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: false)
        try expect(plan.validationError != nil, "ambiguous same-parent folders were not refused")
        try expect(plan.operations.isEmpty, "ambiguous plan still contained executable operations")
    }

    private static func testNativePlannerMapsSystemRoots() throws {
        let target = [
            bookmark("chrome-bar", "Bookmarks Bar", parent: "root", folder: true, browser: .chrome),
            bookmark("chrome-other", "Other Bookmarks", parent: "root", folder: true, browser: .chrome)
        ]
        let desired = [
            bookmark("1", "Favorites", parent: "0", folder: true, browser: .safari),
            bookmark("2", "Bookmarks Menu", parent: "0", folder: true, browser: .safari),
            bookmark("from-menu", "From Menu", parent: "2", browser: .safari)
        ]
        let context = BookmarkNativeTreeContext(inputToken: "tree-v1", browser: .chrome, nodes: target,
                                                rootIds: ["1": "chrome-bar", "2": "chrome-other"], sourceToNativeIds: [:], scopeRootId: nil)
        let plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: false)
        try expect(plan.validationError == nil, "native roots were not mapped by role")
        try expect(plan.operations.count == 1, "system roots became ordinary create operations")
        try expect(plan.operations[0].kind == .create && plan.operations[0].parentId == "chrome-other",
                   "BookmarksMenu content did not map to Chrome Other Bookmarks")
    }

    private static func testNativePlannerDetectsBookmarkConflict() throws {
        let target = [
            bookmark("other", "Other Bookmarks", parent: "root", folder: true, browser: .chrome),
            Bookmark(id: "chrome-fast", title: "Fast.com", url: "https://fast.com/", parentId: "other", isFolder: false, sortIndex: 0, inBookmarksBar: false, dateAdded: nil, sourceBrowser: .chrome)
        ]
        let safariFast = Bookmark(id: "safari-fast", title: "Internet Speed Test | Fast.com", url: "https://fast.com/", parentId: "2", isFolder: false, sortIndex: 0, inBookmarksBar: false, dateAdded: nil, sourceBrowser: .safari)
        let context = BookmarkNativeTreeContext(inputToken: "tree-v1", browser: .chrome, nodes: target,
                                                rootIds: ["2": "other"], sourceToNativeIds: [:], scopeRootId: nil)
        let unresolved = NativeBookmarkPlanner.makePlan(desired: [safariFast], context: context, fullMirror: false)
        try expect(unresolved.conflicts.count == 1, "same URL with different title was silently treated as an addition")
        try expect(unresolved.operations.isEmpty, "unresolved conflict produced executable writes")

        // A conflict blocks the complete target plan, not merely the one
        // conflicting item.  Otherwise an approval dialog could truthfully
        // show a conflict while an unrelated part of the same source delta
        // had already been written.
        let unrelated = Bookmark(
            id: "safari-unrelated", title: "Unrelated", url: "https://unrelated.test/", parentId: "2",
            isFolder: false, sortIndex: 1, inBookmarksBar: false, dateAdded: nil, sourceBrowser: .safari
        )
        let aggregateUnresolved = NativeBookmarkPlanner.makePlan(desired: [safariFast, unrelated], context: context, fullMirror: false)
        try expect(aggregateUnresolved.conflicts.count == 1 && aggregateUnresolved.operations.isEmpty,
                   "an unresolved conflict allowed another operation from the same plan to execute")

        let useSource = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: context, fullMirror: false,
            conflictResolutions: [unresolved.conflicts[0].id: .source]
        )
        try expect(useSource.operations.contains { $0.kind == .update && $0.id == "chrome-fast" },
                   "source choice did not produce a target update")
        let keepBoth = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: context, fullMirror: false,
            conflictResolutions: [unresolved.conflicts[0].id: .both]
        )
        try expect(keepBoth.operations.contains { $0.kind == .create }, "keep-both choice did not preserve both bookmarks")

        let keepTarget = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: context, fullMirror: false,
            conflictResolutions: [unresolved.conflicts[0].id: .target]
        )
        try expect(keepTarget.operations.isEmpty, "target choice unexpectedly wrote over the target bookmark")

        let sameTitleDifferentURL = Bookmark(
            id: "safari-different-url", title: "Fast.com", url: "https://fast.com/other", parentId: "2",
            isFolder: false, sortIndex: 0, inBookmarksBar: false, dateAdded: nil, sourceBrowser: .safari
        )
        let urlConflict = NativeBookmarkPlanner.makePlan(desired: [sameTitleDifferentURL], context: context, fullMirror: false)
        try expect(urlConflict.conflicts.count == 1 && urlConflict.conflicts[0].reason == .url,
                   "same title with different URL was silently treated as an addition")
        try expect(urlConflict.operations.isEmpty, "same-title URL conflict produced executable writes")

        // Native parent IDs are browser-local.  Even if a portable folder
        // chain cannot be resolved, a unique competing URL in the selected
        // scope must be surfaced for a user choice, never treated as a create
        // below an arbitrary root.
        let unresolvedParent = Bookmark(
            id: "safari-fast-unmapped-parent", title: "Internet Speed Test | Fast.com",
            url: "https://fast.com/", parentId: "safari-tools-not-in-target",
            isFolder: false, sortIndex: 0, inBookmarksBar: false, dateAdded: nil, sourceBrowser: .safari
        )
        let crossRootConflict = NativeBookmarkPlanner.makePlan(desired: [unresolvedParent], context: context, fullMirror: false)
        try expect(crossRootConflict.conflicts.count == 1 && crossRootConflict.operations.isEmpty,
                   "cross-browser parent-ID mismatch silently created a competing bookmark")

        // A persisted identity map only proves that the items were once the
        // same bookmark. It must not silently overwrite an independently
        // changed target title or URL on a later sync.
        let mappedContext = BookmarkNativeTreeContext(
            inputToken: "tree-v2", browser: .chrome, nodes: target,
            rootIds: ["2": "other"], sourceToNativeIds: ["safari-fast": "chrome-fast"], scopeRootId: nil
        )
        let mappedConflict = NativeBookmarkPlanner.makePlan(desired: [safariFast], context: mappedContext, fullMirror: false)
        try expect(mappedConflict.conflicts.count == 1 && mappedConflict.operations.isEmpty,
                   "mapped title disagreement bypassed conflict resolution")
        let mappedSource = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: mappedContext, fullMirror: false,
            conflictResolutions: [mappedConflict.conflicts[0].id: .source]
        )
        try expect(mappedSource.operations.count == 1 && mappedSource.operations[0].kind == .update
                    && mappedSource.operations[0].id == "chrome-fast",
                   "mapped source choice did not update the mapped target")
        let mappedTarget = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: mappedContext, fullMirror: false,
            conflictResolutions: [mappedConflict.conflicts[0].id: .target]
        )
        try expect(mappedTarget.operations.isEmpty,
                   "mapped target choice unexpectedly changed the target")
        let mappedBoth = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: mappedContext, fullMirror: false,
            conflictResolutions: [mappedConflict.conflicts[0].id: .both]
        )
        try expect(mappedBoth.operations.contains { $0.kind == .create },
                   "keeping both after a mapped conflict updated the existing target instead")
        let mappedBothFullMirror = NativeBookmarkPlanner.makePlan(
            desired: [safariFast], context: mappedContext, fullMirror: true,
            conflictResolutions: [mappedConflict.conflicts[0].id: .both]
        )
        try expect(mappedBothFullMirror.operations.contains { $0.kind == .create },
                   "full-mirror keep-both did not create the source version")
        try expect(!mappedBothFullMirror.operations.contains { $0.kind == .removeTree && $0.id == "chrome-fast" },
                   "full-mirror keep-both scheduled the original target for deletion")

        // Conflict handling is a planner rule, not a Safari special case.
        // Every supported source/target pair must stop before an ambiguous
        // overwrite and offer the same choice.
        for sourceBrowser in Browser.allCases {
            for targetBrowser in Browser.allCases where targetBrowser != sourceBrowser {
                var source = safariFast
                source.sourceBrowser = sourceBrowser
                var targetFast = target[1]
                targetFast.sourceBrowser = targetBrowser
                let pairContext = BookmarkNativeTreeContext(
                    inputToken: "pair-\(sourceBrowser.rawValue)-\(targetBrowser.rawValue)", browser: targetBrowser,
                    nodes: [target[0], targetFast], rootIds: ["2": "other"], sourceToNativeIds: [:], scopeRootId: nil
                )
                let pairPlan = NativeBookmarkPlanner.makePlan(desired: [source], context: pairContext, fullMirror: false)
                try expect(pairPlan.conflicts.count == 1 && pairPlan.operations.isEmpty,
                           "conflict handling differed for \(sourceBrowser.rawValue) -> \(targetBrowser.rawValue)")
            }
        }
    }

    private static func testNativePlannerPreservesOutsideScope() throws {
        let target = [
            bookmark("bar", "Bookmarks Bar", parent: "root", folder: true, browser: .chrome),
            bookmark("scope", "Selected", parent: "bar", folder: true, browser: .chrome),
            bookmark("inside", "Old", parent: "scope", browser: .chrome),
            bookmark("outside", "Untouched", parent: "bar", browser: .chrome)
        ]
        let desired = [bookmark("new", "New", parent: "1", browser: .safari)]
        let context = BookmarkNativeTreeContext(inputToken: "tree-v1", browser: .chrome, nodes: target,
                                                rootIds: ["1": "bar"], sourceToNativeIds: [:], scopeRootId: "scope")
        let plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: true)
        try expect(plan.validationError == nil, "valid selected scope was rejected")
        try expect(plan.operations.contains { $0.kind == .removeTree && $0.id == "inside" }, "stale in-scope node was not removed")
        try expect(!plan.operations.contains { $0.id == "outside" }, "out-of-scope node entered the plan")
        try expect(plan.operations.first { $0.kind == .create }?.parentId == "scope", "new node escaped the selected scope")
    }

    private static func testNativePlannerRefusesMappedOutsideScope() throws {
        let target = [
            bookmark("bar", "Bookmarks Bar", parent: "root", folder: true, browser: .chrome),
            bookmark("scope", "Selected", parent: "bar", folder: true, browser: .chrome),
            bookmark("outside", "Same", parent: "bar", browser: .chrome)
        ]
        let desired = [bookmark("source", "Same", parent: "1", browser: .safari)]
        let context = BookmarkNativeTreeContext(inputToken: "tree-v1", browser: .chrome, nodes: target,
                                                rootIds: ["1": "bar"], sourceToNativeIds: ["source": "outside"], scopeRootId: "scope")
        let plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: false)
        try expect(plan.validationError != nil, "out-of-scope mapped identity was accepted")
        try expect(plan.operations.isEmpty, "out-of-scope mapped identity produced executable operations")
    }

    private static func testNativeRemovalPlan() throws {
        let target = [
            bookmark("bar", "Bookmarks Bar", parent: "root", folder: true, browser: .chrome),
            bookmark("scope", "Selected", parent: "bar", folder: true, browser: .chrome),
            Bookmark(id: "chrome-deleted", title: "Delete Me", url: "https://example.test/delete", parentId: "scope",
                     isFolder: false, sortIndex: 0, inBookmarksBar: true, dateAdded: nil, sourceBrowser: .chrome),
            bookmark("outside", "Outside", parent: "bar", browser: .chrome)
        ]
        let removed = Bookmark(id: "safari-deleted", title: "Delete Me", url: "https://example.test/delete", parentId: "2",
                               isFolder: false, sortIndex: 0, inBookmarksBar: false, dateAdded: nil, sourceBrowser: .safari)
        let context = BookmarkNativeTreeContext(
            inputToken: "removal-v1", browser: .chrome, nodes: target,
            rootIds: ["1": "bar"], sourceToNativeIds: ["safari-deleted": "chrome-deleted"], scopeRootId: "scope"
        )
        let plan = NativeBookmarkPlanner.makeRemovalPlan(removals: [removed], context: context)
        try expect(plan.validationError == nil, "mapped in-scope deletion was rejected")
        try expect(plan.operations.count == 1 && plan.operations[0].kind == .removeTree && plan.operations[0].id == "chrome-deleted",
                   "source deletion did not become a target remove operation")
        try expect(!plan.operations.contains { $0.id == "outside" }, "deletion plan escaped the selected folder scope")

        let duplicate = Bookmark(id: "duplicate", title: "Delete Me", url: "https://example.test/delete", parentId: "scope",
                                 isFolder: false, sortIndex: 1, inBookmarksBar: true, dateAdded: nil, sourceBrowser: .chrome)
        let ambiguousContext = BookmarkNativeTreeContext(
            inputToken: "removal-v2", browser: .chrome, nodes: target + [duplicate],
            rootIds: ["1": "bar"], sourceToNativeIds: [:], scopeRootId: "scope"
        )
        let ambiguous = NativeBookmarkPlanner.makeRemovalPlan(removals: [removed], context: ambiguousContext)
        try expect(ambiguous.validationError != nil && ambiguous.operations.isEmpty,
                   "ambiguous deletion identity selected an arbitrary target")
    }

    private static func testRestoreAcceptsExistingParent() throws {
        let target = [
            bookmark("root", "Root", parent: nil, folder: true, browser: .chrome),
            bookmark("scope", "Selected", parent: "root", folder: true, browser: .chrome),
            bookmark("existing-parent", "Work", parent: "scope", folder: true, browser: .chrome)
        ]
        let restored = bookmark("deleted", "Restore Me", parent: "existing-parent", browser: .chrome)
        let context = BookmarkNativeTreeContext(inputToken: "tree-v1", browser: .chrome, nodes: target,
                                                rootIds: ["1": "root"], sourceToNativeIds: [:], scopeRootId: "scope")
        let plan = NativeBookmarkPlanner.makePlan(desired: [restored], context: context, fullMirror: false)
        try expect(plan.validationError == nil, "existing in-scope parent was rejected")
        try expect(plan.operations.count == 1 && plan.operations[0].kind == .create,
                   "restore did not create the missing bookmark")
        try expect(plan.operations[0].parentId == "existing-parent", "restore changed the recorded parent")
    }

    private static func snapshot(_ id: String, _ bookmarks: [Bookmark]) -> BookmarkSnapshotRecord {
        BookmarkSnapshotRecord(id: id, capturedAt: Date(), sourceBrowser: "chrome", bookmarks: bookmarks)
    }

    private static func testSnapshotDiffDeletion() throws {
        let folder = bookmark("folder", "Folder", parent: "2", folder: true)
        let child = bookmark("child", "Child", parent: "folder")
        let delta = BookmarkSnapshotDiffer.diff(older: snapshot("old", [folder, child]), newer: snapshot("new", []))
        try expect(delta.changes.count == 1, "folder subtree produced duplicate child deletions")
        try expect(delta.changes[0].kind == .removed && delta.changes[0].nodeId == "folder", "missing folder was not a deletion")
    }

    private static func testSnapshotDiffMoveAndReorder() throws {
        var a = bookmark("a", "A", parent: "1")
        var b = bookmark("b", "B", parent: "1")
        var c = bookmark("c", "C", parent: "1")
        a.sortIndex = 0; b.sortIndex = 1; c.sortIndex = 2
        var movedA = a; movedA.parentId = "2"; movedA.sortIndex = 0
        var reorderedB = b; reorderedB.sortIndex = 1
        var reorderedC = c; reorderedC.sortIndex = 0
        let delta = BookmarkSnapshotDiffer.diff(older: snapshot("old", [a, b, c]),
                                                newer: snapshot("new", [movedA, reorderedC, reorderedB]))
        try expect(delta.changes.contains { $0.kind == .moved && $0.nodeId == "a" }, "cross-parent move was not identified")
        // Sibling indexes are deliberately not treated as user operations.
        try expect(!delta.changes.contains { $0.kind == .reordered }, "index-only differences became reorder operations")
    }

    private static func testSnapshotDeltaPayloadIncludesParents() throws {
        let folder = bookmark("folder", "Folder", parent: "2", folder: true)
        let child = bookmark("child", "Child", parent: "folder")
        let delta = BookmarkSnapshotDiffer.diff(older: snapshot("old", [folder]), newer: snapshot("new", [folder, child]))
        let payload = BookmarkSnapshotDiffer.payload(for: delta, current: [folder, child])
        try expect(Set(payload.map(\.id)) == ["folder", "child"], "changed child payload omitted its parent chain")
    }

    private static func testStableSnapshotConflict() throws {
        let safariFolder = bookmark("safari-tools", "Tools", parent: "1", folder: true, browser: .safari)
        let safariFast = Bookmark(id: "safari-fast", title: "Internet Speed Test | Fast.com", url: "https://fast.com/",
                                  parentId: "safari-tools", isFolder: false, sortIndex: 0, inBookmarksBar: true,
                                  dateAdded: nil, sourceBrowser: .safari)
        let chromeFolder = bookmark("chrome-tools", "Tools", parent: "1", folder: true, browser: .chrome)
        let chromeFast = Bookmark(id: "chrome-fast", title: "Fast.com", url: "https://fast.com/",
                                  parentId: "chrome-tools", isFolder: false, sortIndex: 0, inBookmarksBar: true,
                                  dateAdded: nil, sourceBrowser: .chrome)
        let conflicts = BookmarkStableConflictDetector.conflicts(
            source: [safariFolder, safariFast], target: [chromeFolder, chromeFast]
        )
        try expect(conflicts.count == 1, "stable snapshots hid the same-URL title conflict")
        try expect(conflicts[0].source.id == "safari-fast" && conflicts[0].target.id == "chrome-fast",
                   "stable conflict did not retain the two competing bookmarks")

        let unrelated = bookmark("chrome-other", "Other", parent: "chrome-tools", browser: .chrome)
        try expect(BookmarkStableConflictDetector.conflicts(
            source: [safariFolder, safariFast], target: [chromeFolder, chromeFast, unrelated]
        ).count == 1, "stable conflict scan treated unrelated bookmarks as a merge plan")
    }

    // MARK: Aggregate planning

    private static func leaf(_ id: String, _ title: String, _ url: String, parent: String, browser: Browser) -> Bookmark {
        Bookmark(id: id, title: title, url: url, parentId: parent, isFolder: false, sortIndex: 0,
                 inBookmarksBar: parent == "1", dateAdded: nil, sourceBrowser: browser)
    }

    private static func context(_ browser: Browser, _ nodes: [Bookmark], token: String = "tree-v1") -> BookmarkNativeTreeContext {
        let prefix = browser.rawValue
        let roots = [
            bookmark("\(prefix)-bar", "Bar", parent: "\(prefix)-root", folder: true, browser: browser),
            bookmark("\(prefix)-other", "Other", parent: "\(prefix)-root", folder: true, browser: browser)
        ]
        return BookmarkNativeTreeContext(inputToken: token, browser: browser, nodes: roots + nodes,
                                         rootIds: ["1": "\(prefix)-bar", "2": "\(prefix)-other", "3": "\(prefix)-other"],
                                         sourceToNativeIds: [:], scopeRootId: nil)
    }

    /// Safari, Chrome and Edge each added a different bookmark in a different
    /// folder. Every target must receive both other browsers' additions in
    /// one plan, executable with a single input token.
    private static func testAggregatePlanKeepsEverySource() throws {
        let chromeAdd = [bookmark("c-folder", "Chrome Folder", parent: "1", folder: true, browser: .chrome),
                         leaf("c-new", "Chrome New", "https://chrome.test/", parent: "c-folder", browser: .chrome)]
        let safariAdd = [leaf("s-new", "Safari New", "https://safari.test/", parent: "2", browser: .safari)]
        let edgeTarget = context(.edge, [])
        let plan = BookmarkAggregatePlanner.plan(
            target: .edge, context: edgeTarget,
            contributions: [.init(source: .chrome, desired: chromeAdd, removals: []),
                            .init(source: .safari, desired: safariAdd, removals: [])],
            conflicts: [])
        try expect(plan.inputToken == "tree-v1", "aggregate plan lost the target token")
        try expect(plan.routes.count == 2, "one source route replaced another for the same target")
        try expect(plan.routes.allSatisfy { $0.validationError == nil }, "a route failed validation")
        let creates = plan.operations.filter { $0.kind == .create }
        try expect(Set(creates.compactMap(\.title)) == ["Chrome Folder", "Chrome New", "Safari New"],
                   "aggregate plan omitted a source's additions")
        try expect(Set(creates.map(\.id)).count == creates.count, "planned IDs collide across sources")
        let chromeNew = try unwrap(creates.first { $0.title == "Chrome New" }, "missing Chrome child")
        let chromeFolder = try unwrap(creates.first { $0.title == "Chrome Folder" }, "missing Chrome folder")
        try expect(chromeNew.parentId == chromeFolder.id, "child was not placed in its planned folder")
        try expect(plan.routes[0].changes.contains { $0.title == "Chrome New" && $0.kind == .added }, "Chrome route rows missing")
        try expect(plan.routes[1].changes.contains { $0.title == "Safari New" && $0.kind == .added }, "Safari route rows missing")

        // Two sources adding the same bookmark produce one write.
        let duplicate = BookmarkAggregatePlanner.plan(
            target: .edge, context: edgeTarget,
            contributions: [.init(source: .chrome, desired: safariAdd.map { var b = $0; b.id = "c-dup"; return b }, removals: []),
                            .init(source: .safari, desired: safariAdd, removals: [])],
            conflicts: [])
        try expect(duplicate.operations.filter { $0.kind == .create }.count == 1, "identical additions from two sources were both created")
    }

    private static func fastScenario() -> (safari: BookmarkNativeTreeContext, chrome: BookmarkNativeTreeContext, edge: BookmarkNativeTreeContext,
                                           safariDelta: [Bookmark], chromeDelta: [Bookmark]) {
        let safariFast = leaf("s-fast", "Internet Speed Test | Fast.com", "https://fast.com/", parent: "2", browser: .safari)
        let chromeFast = leaf("c-fast", "Fast.com", "https://fast.com/", parent: "2", browser: .chrome)
        let safariNative = leaf("s-fast", "Internet Speed Test | Fast.com", "https://fast.com/", parent: "safari-other", browser: .safari)
        let chromeNative = leaf("c-fast", "Fast.com", "https://fast.com/", parent: "chrome-other", browser: .chrome)
        return (context(.safari, [safariNative], token: "safari-v1"), context(.chrome, [chromeNative], token: "chrome-v1"),
                context(.edge, [], token: "edge-v1"), [safariFast], [chromeFast])
    }

    private static func unifiedConflicts(_ plans: [BookmarkTargetPlan]) -> [BookmarkSyncConflict] {
        var all: [BookmarkSyncConflict] = []
        for plan in plans { for conflict in plan.conflicts { BookmarkAggregatePlanner.append(conflict, to: &all) } }
        return all
    }

    private static func testAggregateConflictResolution() throws {
        let s = fastScenario()
        let toSafari = [BookmarkSourceContribution(source: .chrome, desired: s.chromeDelta, removals: [])]
        let toChrome = [BookmarkSourceContribution(source: .safari, desired: s.safariDelta, removals: [])]
        let toEdge = [BookmarkSourceContribution(source: .chrome, desired: s.chromeDelta, removals: []),
                      BookmarkSourceContribution(source: .safari, desired: s.safariDelta, removals: [])]
        let detect = [
            BookmarkAggregatePlanner.plan(target: .safari, context: s.safari, contributions: toSafari, conflicts: []),
            BookmarkAggregatePlanner.plan(target: .chrome, context: s.chrome, contributions: toChrome, conflicts: [])
        ]
        let conflicts = unifiedConflicts(detect)
        try expect(conflicts.count == 1, "the same dispute seen from both directions was not unified")
        try expect(conflicts[0].first.browsers.union(conflicts[0].second.browsers) == [.safari, .chrome], "conflict browsers lost")

        // The disputed versions are not offered as ordinary additions to Edge.
        let edgeDisplay = BookmarkAggregatePlanner.plan(target: .edge, context: s.edge, contributions: toEdge, conflicts: conflicts)
        try expect(edgeDisplay.operations.isEmpty, "a disputed version was planned as an ordinary addition")

        let keepChrome = conflicts[0].first.browsers.contains(.chrome) ? BookmarkConflictResolution.source : .target
        let choice = [conflicts[0].id: keepChrome]
        let safariApply = BookmarkAggregatePlanner.plan(target: .safari, context: s.safari, contributions: toSafari,
                                                        conflicts: conflicts, resolutions: choice)
        let safariOps = try unwrap(safariApply.resolution, "no resolution step for Safari").operations
        try expect(safariOps.count == 1 && safariOps[0].kind == .update && safariOps[0].id == "s-fast" && safariOps[0].title == "Fast.com",
                   "keeping Chrome did not rewrite Safari's version")
        let chromeApply = BookmarkAggregatePlanner.plan(target: .chrome, context: s.chrome, contributions: toChrome,
                                                        conflicts: conflicts, resolutions: choice)
        try expect(chromeApply.operations.isEmpty, "keeping Chrome still wrote Chrome")
        let edgeApply = BookmarkAggregatePlanner.plan(target: .edge, context: s.edge, contributions: toEdge,
                                                      conflicts: conflicts, resolutions: choice)
        let edgeOps = edgeApply.operations
        try expect(edgeOps.count == 1 && edgeOps[0].kind == .create && edgeOps[0].title == "Fast.com",
                   "the chosen version did not reach the uninvolved browser exactly once")
    }

    private static func testAggregateConflictKeepBoth() throws {
        let s = fastScenario()
        let toChrome = [BookmarkSourceContribution(source: .safari, desired: s.safariDelta, removals: [])]
        let conflicts = unifiedConflicts([
            BookmarkAggregatePlanner.plan(target: .chrome, context: s.chrome, contributions: toChrome, conflicts: [])
        ])
        let choice = [try unwrap(conflicts.first, "no conflict").id: BookmarkConflictResolution.both]
        let chrome = BookmarkAggregatePlanner.plan(target: .chrome, context: s.chrome, contributions: toChrome,
                                                   conflicts: conflicts, resolutions: choice)
        try expect(chrome.operations.count == 1 && chrome.operations[0].kind == .create
                   && chrome.operations[0].title == "Internet Speed Test | Fast.com",
                   "keep both did not add the other version to Chrome")
        let safari = BookmarkAggregatePlanner.plan(target: .safari, context: s.safari, contributions: [],
                                                   conflicts: conflicts, resolutions: choice)
        try expect(safari.operations.count == 1 && safari.operations[0].title == "Fast.com"
                   && safari.operations[0].kind == .create, "keep both did not add Chrome's version to Safari")
        let edge = BookmarkAggregatePlanner.plan(target: .edge, context: s.edge, contributions: [],
                                                 conflicts: conflicts, resolutions: choice)
        try expect(edge.operations.filter { $0.kind == .create }.count == 2, "keep both did not reach the third browser")
    }

    private static func testAggregatePruneDependencies() throws {
        let folder = BookmarkMutationOperation(id: "browsync-chrome-planned-0", kind: .create, parentId: "bar", title: "F")
        let child = BookmarkMutationOperation(id: "browsync-chrome-planned-1", kind: .create, parentId: folder.id, title: "C", url: "https://c.test/")
        let other = BookmarkMutationOperation(id: "native-9", kind: .update, title: "T")
        let pruned = BookmarkAggregatePlanner.pruneDependencies([child, other])
        try expect(pruned == [other], "a child of an unselected planned folder was still dispatched")
        try expect(BookmarkAggregatePlanner.pruneDependencies([folder, child, other]).count == 3, "valid dependencies were pruned")
    }

    private static func testBaselineRevertsUnhandledChanges() throws {
        let kept = bookmark("kept", "Kept", parent: "2")
        let added = bookmark("added", "Added", parent: "2")
        let removed = bookmark("removed", "Removed", parent: "2")
        var renamed = bookmark("renamed", "Old", parent: "2")
        let baseline = snapshot("base", [kept, removed, renamed])
        renamed.title = "New"
        let observed = [kept, added, renamed]
        let delta = BookmarkSnapshotDiffer.diff(older: baseline, newer: snapshot("now", observed))
        try expect(delta.changes.count == 3, "baseline delta did not contain add, remove and rename")
        let unhandled = delta.changes.filter { $0.nodeId != "renamed" }
        let next = BookmarkBaseline.advanced(observed: observed, reverting: unhandled)
        let again = BookmarkSnapshotDiffer.diff(older: snapshot("next", next), newer: snapshot("now", observed))
        try expect(Set(again.changes.map(\.id)) == Set(unhandled.map(\.id)),
                   "an unchecked change disappeared or an applied change was offered again")
    }

    private static func testIdentityDriftIsNotAChange() throws {
        let before = leaf("50", "Docs", "https://docs.test/", parent: "2", browser: .chrome)
        let after = leaf("SAFARI-UUID", "Docs", "https://docs.test/", parent: "2", browser: .chrome)
        let real = leaf("51", "Gone", "https://gone.test/", parent: "2", browser: .chrome)
        let delta = BookmarkSnapshotDiffer.ignoringIdentityDrift(
            BookmarkSnapshotDiffer.diff(older: snapshot("old", [before, real]), newer: snapshot("new", [after])))
        try expect(delta.changes.count == 1 && delta.changes[0].kind == .removed && delta.changes[0].nodeId == "51",
                   "an ID remap became a delete/re-create or hid a real deletion")
    }

    private static func record(_ browser: Browser, _ date: TimeInterval, _ nodes: [Bookmark]) -> BookmarkSnapshotRecord {
        BookmarkSnapshotRecord(id: UUID().uuidString, capturedAt: Date(timeIntervalSince1970: date), sourceBrowser: browser.rawValue, bookmarks: nodes)
    }

    private static func testReconcileMissedAddition() throws {
        let folder = bookmark("c-f", "Chrome Folder", parent: "1", folder: true, browser: .chrome)
        let item = leaf("c-x", "X", "https://x.test/", parent: "c-f", browser: .chrome)
        let chromeLive = context(.chrome, [bookmark("c-f", "Chrome Folder", parent: "chrome-bar", folder: true, browser: .chrome),
                                           leaf("c-x", "X", "https://x.test/", parent: "c-f", browser: .chrome)])
        let result = BookmarkReconciler.reconcile(
            observed: [.chrome: [folder, item], .safari: [], .edge: []],
            live: [.chrome: chromeLive, .safari: context(.safari, []), .edge: context(.edge, [])],
            history: [.safari: [record(.safari, 100, [])], .edge: [record(.edge, 100, [])]],
            deletions: [], pendingURLs: [], now: Date(timeIntervalSince1970: 1000))
        try expect(Set(result.additions.keys) == ["chrome>safari", "chrome>edge"], "missed addition was not offered to every lacking browser")
        try expect(result.additions["chrome>safari"]?.map(\.id) == ["c-f", "c-x"], "missed addition lost its folder chain")
        try expect(result.removals.isEmpty, "absence alone was treated as a deletion")
    }

    private static func testReconcileMissedDeletion() throws {
        let x = leaf("c-x", "X", "https://x.test/", parent: "2", browser: .chrome)
        let chromeLive = context(.chrome, [leaf("c-x", "X", "https://x.test/", parent: "chrome-other", browser: .chrome)])
        let safariHad = leaf("s-x", "X", "https://x.test/", parent: "2", browser: .safari)
        let deleted = BookmarkReconciler.reconcile(
            observed: [.chrome: [x], .safari: []],
            live: [.chrome: chromeLive, .safari: context(.safari, [])],
            history: [.safari: [record(.safari, 100, [safariHad]), record(.safari, 200, [])],
                      .chrome: [record(.chrome, 50, [x]), record(.chrome, 300, [x])]],
            deletions: [], pendingURLs: [], now: Date(timeIntervalSince1970: 1000))
        try expect(deleted.removals["safari>chrome"]?.map(\.id) == ["c-x"] && deleted.additions.isEmpty,
                   "a newer Safari deletion was not propagated (or the stale copy was re-added)")

        let readded = BookmarkReconciler.reconcile(
            observed: [.chrome: [x], .safari: []],
            live: [.chrome: chromeLive, .safari: context(.safari, [])],
            history: [.safari: [record(.safari, 100, [safariHad]), record(.safari, 200, [])],
                      .chrome: [record(.chrome, 50, []), record(.chrome, 300, [x])]],
            deletions: [], pendingURLs: [], now: Date(timeIntervalSince1970: 1000))
        try expect(readded.additions["chrome>safari"] != nil && readded.removals.isEmpty,
                   "a bookmark re-added after the deletion was deleted again")
    }

    private static func testReconcileSkipsAmbiguous() throws {
        let x = leaf("c-x", "X", "https://x.test/", parent: "2", browser: .chrome)
        let chromeLive = context(.chrome, [leaf("c-x", "X", "https://x.test/", parent: "chrome-other", browser: .chrome)])
        let pending = BookmarkReconciler.reconcile(
            observed: [.chrome: [x]], live: [.chrome: chromeLive, .edge: context(.edge, [])],
            history: [:], deletions: [], pendingURLs: ["https://x.test/"])
        try expect(pending.isEmpty, "a URL already handled by a pending change was reconciled again")

        var scoped = context(.edge, [bookmark("e-scope", "Synced", parent: "edge-bar", folder: true, browser: .edge),
                                     leaf("e-x", "X", "https://x.test/", parent: "edge-other", browser: .edge)])
        scoped.scopeRootId = "e-scope"
        let outside = BookmarkReconciler.reconcile(
            observed: [.chrome: [x]], live: [.chrome: chromeLive, .edge: scoped],
            history: [.edge: [record(.edge, 100, [x]), record(.edge, 200, [])]], deletions: [], pendingURLs: [])
        try expect(outside.isEmpty, "a bookmark outside the selected folder was treated as missing or deleted")
    }

    private static func testUnexplainedChangesSurviveWrite() throws {
        let a = leaf("a", "A", "https://a.test/", parent: "2", browser: .chrome)
        let ours = leaf("new-id", "Ours", "https://ours.test/", parent: "2", browser: .chrome)
        let user = leaf("user", "User", "https://user.test/", parent: "2", browser: .chrome)
        var renamed = a; renamed.title = "A renamed by user"
        let op = BookmarkMutationOperation(id: "browsync-safari-planned-0", kind: .create, parentId: "chrome-other",
                                           title: "Ours", url: "https://ours.test/")
        let unexplained = BookmarkBaseline.unexplainedChanges(
            observed: [a], fresh: [renamed, ours, user], operations: [op],
            nativeNodes: [leaf("a", "A", "https://a.test/", parent: "chrome-other", browser: .chrome)])
        try expect(Set(unexplained.map(\.id)) == ["added|user", "modified|a"],
                   "our write was not recognised or the user's concurrent edits were absorbed")
        let baseline = BookmarkBaseline.advanced(observed: [renamed, ours, user], reverting: unexplained)
        let next = BookmarkSnapshotDiffer.diff(older: snapshot("b", baseline), newer: snapshot("n", [renamed, ours, user]))
        try expect(Set(next.changes.map(\.id)) == ["added|user", "modified|a"], "concurrent edits were not detected by the next sync")
    }

    private static func testIgnoredChangesAreFiltered() throws {
        let chromeAdd = [bookmark("c-folder", "Chrome Folder", parent: "1", folder: true, browser: .chrome),
                         leaf("c-new", "Chrome New", "https://chrome.test/", parent: "c-folder", browser: .chrome),
                         leaf("c-other", "Other", "https://other.test/", parent: "1", browser: .chrome)]
        let plan = BookmarkAggregatePlanner.plan(target: .edge, context: context(.edge, []),
                                                 contributions: [.init(source: .chrome, desired: chromeAdd, removals: [])],
                                                 conflicts: [])
        let folderChange = try unwrap(plan.routes[0].changes.first { $0.title == "Chrome Folder" }, "missing folder row")
        let ignored: Set<String> = [BookmarkIgnore.changeKey(target: .edge, change: folderChange)]
        let filtered = BookmarkIgnore.filtered(plan, ignored: ignored)
        try expect(filtered.operations.map(\.title) == ["Other"], "an ignored folder or its new contents were still planned")
        try expect(filtered.routes[0].changes.map(\.title) == ["Other"], "ignored rows were still shown")
        let otherTarget = BookmarkIgnore.filtered(
            BookmarkAggregatePlanner.plan(target: .safari, context: context(.safari, []),
                                          contributions: [.init(source: .chrome, desired: chromeAdd, removals: [])], conflicts: []),
            ignored: ignored)
        try expect(otherTarget.operations.count == 3, "ignoring a change for Edge also hid it for Safari")
    }

    private static func testIgnoredConflictDoesNotBlock() throws {
        let s = fastScenario()
        let toChrome = [BookmarkSourceContribution(source: .safari, desired: s.safariDelta, removals: [])]
        let conflicts = unifiedConflicts([
            BookmarkAggregatePlanner.plan(target: .chrome, context: s.chrome, contributions: toChrome, conflicts: [])
        ])
        let id = try unwrap(conflicts.first, "no conflict").id
        let plan = BookmarkAggregatePlanner.plan(target: .edge, context: s.edge, contributions: [], conflicts: conflicts,
                                                 resolutions: [:], ignoredConflicts: [id])
        try expect(plan.resolution?.validationError == nil && plan.operations.isEmpty,
                   "an ignored conflict blocked the write or was still resolved")
    }

    // MARK: Safari Bookmarks.plist (synthetic)

    private static func safariLeaf(_ uuid: String, _ title: String, _ url: String) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": uuid, "URLString": url, "URIDictionary": ["title": title]]
    }

    private static func safariFolder(_ uuid: String, _ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": uuid, "Title": title, "Children": children]
    }

    /// Favorites: Synced/{A}, Outside · Menu: Dup, Dup (duplicate titles) ·
    /// plus History and Reading List, which must never be touched.
    private static func syntheticSafariPlist() -> [String: Any] {
        ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "WebBookmarkIdentifier": "History", "Title": "History", "WebBookmarkUUID": "HISTORY"],
            safariFolder("BAR", "BookmarksBar", [
                safariFolder("SYNC", "Synced", [safariLeaf("A", "A", "https://a.test/")]),
                safariLeaf("OUT", "Outside", "https://out.test/")
            ]),
            safariFolder("MENU", "BookmarksMenu", [safariFolder("DUP1", "Dup", []), safariFolder("DUP2", "Dup", [])]),
            safariFolder("READING", "com.apple.ReadingList", [safariLeaf("RL1", "Later", "https://later.test/")])
        ]]
    }

    private static func plistData(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Everything except the selected folder's subtree, as comparable bytes.
    private static func outsideOfSynced(_ plist: [String: Any]) throws -> Data {
        var copy = plist
        var children = copy["Children"] as? [[String: Any]] ?? []
        for index in children.indices where children[index]["WebBookmarkUUID"] as? String == "BAR" {
            var bar = children[index]["Children"] as? [[String: Any]] ?? []
            for inner in bar.indices where bar[inner]["WebBookmarkUUID"] as? String == "SYNC" { bar[inner]["Children"] = [] }
            children[index]["Children"] = bar
        }
        copy["Children"] = children
        return try plistData(copy)
    }

    private static func testSafariPlanStaysInScope() throws {
        let plist = syntheticSafariPlist()
        let read = SafariPlist.nativeContext(plist: plist, data: try plistData(plist), folderPath: "Bookmarks Bar/Synced")
        let context = try unwrap(read.context, "Safari context failed: \(read.error ?? "")")
        try expect(context.scopeRootId == "SYNC", "selected folder was not bound to its unique node")
        // Chrome added a folder with a bookmark at its synced root.
        let desired = [bookmark("c-f", "Chrome Folder", parent: "2", folder: true, browser: .chrome),
                       leaf("c-new", "New", "https://new.test/", parent: "c-f", browser: .chrome)]
        let plan = BookmarkAggregatePlanner.plan(target: .safari, context: context,
                                                 contributions: [.init(source: .chrome, desired: desired, removals: [])],
                                                 conflicts: [])
        try expect(plan.operations.count == 2, "expected a folder and a bookmark creation")
        let result = SafariPlist.applying(plan.operations, to: plist, scopeRootId: context.scopeRootId)
        let written = try unwrap(result.plist, "valid in-scope plan was refused: \(result.error ?? "")")
        let parsed = SafariPlist.parseBookmarks(written)
        let folder = try unwrap(parsed.first { $0.title == "Chrome Folder" && $0.isFolder }, "folder was not created")
        try expect(folder.parentId == "SYNC", "folder was created outside the selected folder")
        try expect(parsed.contains { $0.title == "New" && $0.url == "https://new.test/" && $0.parentId == folder.id },
                   "bookmark was not created inside its new folder")
        let outsideAfter = try outsideOfSynced(written), outsideBefore = try outsideOfSynced(plist)
        try expect(outsideAfter == outsideBefore,
                   "nodes outside the selected folder (including History and Reading List) changed")
    }

    private static func testSafariExecutorRefusals() throws {
        let plist = syntheticSafariPlist()
        let rename = SafariPlist.applying([.init(id: "A", kind: .update, title: "A renamed", url: "https://a.test/")],
                                          to: plist, scopeRootId: "SYNC")
        let renamed = try unwrap(rename.plist, "in-scope rename was refused: \(rename.error ?? "")")
        let parsedRename = SafariPlist.parseBookmarks(renamed)
        try expect(parsedRename.first { $0.id == "A" }.map { $0.title == "A renamed" && $0.parentId == "SYNC" && $0.sortIndex == 0 } == true,
                   "rename did not keep the bookmark's identity and position")

        let removal = SafariPlist.applying([.init(id: "A", kind: .removeTree)], to: plist, scopeRootId: "SYNC")
        try expect(removal.plist.map { !SafariPlist.parseBookmarks($0).contains { $0.id == "A" } } == true,
                   "in-scope removal was not applied")

        let refusals: [(String, [BookmarkMutationOperation])] = [
            ("removing a bookmark outside the folder", [.init(id: "OUT", kind: .removeTree)]),
            ("moving an outside bookmark into the folder", [.init(id: "OUT", kind: .move, parentId: "SYNC")]),
            ("creating into an outside folder", [.init(id: "browsync-x-planned-0", kind: .create, parentId: "MENU", title: "X", url: "https://x.test/")]),
            ("removing a system root", [.init(id: "1", kind: .removeTree)]),
            ("creating into a missing parent", [.init(id: "browsync-x-planned-0", kind: .create, parentId: "NOPE", title: "X", url: "https://x.test/")]),
            ("updating a missing bookmark", [.init(id: "NOPE", kind: .update, title: "X", url: nil)]),
            ("a valid operation followed by an invalid one",
             [.init(id: "A", kind: .update, title: "Changed", url: "https://a.test/"), .init(id: "OUT", kind: .removeTree)])
        ]
        for (name, operations) in refusals {
            let result = SafariPlist.applying(operations, to: plist, scopeRootId: "SYNC")
            try expect(result.plist == nil && result.error != nil, "Safari executor allowed \(name)")
        }
        // Without a selected folder the whole library is in scope, but system
        // roots stay protected.
        try expect(SafariPlist.applying([.init(id: "OUT", kind: .removeTree)], to: plist, scopeRootId: nil).plist != nil,
                   "whole-library sync could not remove an ordinary bookmark")
        try expect(SafariPlist.applying([.init(id: "2", kind: .removeTree)], to: plist, scopeRootId: nil).plist == nil,
                   "whole-library sync removed the Bookmarks Menu root")
    }

    private static func testSafariContextBinding() throws {
        let plist = syntheticSafariPlist()
        let data = try plistData(plist)
        try expect(SafariPlist.nativeContext(plist: plist, data: data, folderPath: "Bookmarks Menu/Dup").context == nil,
                   "a duplicate folder title was bound instead of refused")
        try expect(SafariPlist.nativeContext(plist: plist, data: data, folderPath: "Bookmarks Bar/Missing").context == nil,
                   "a missing folder was bound instead of refused")
        let context = try unwrap(SafariPlist.nativeContext(plist: plist, data: data, folderPath: nil).context, "whole-library context failed")
        try expect(context.inputToken == SafariPlist.digest(data), "input token is not bound to the file bytes")
        var changed = plist
        changed["Children"] = (plist["Children"] as? [[String: Any]] ?? []) + [safariLeaf("NEW", "New", "https://new.test/")]
        let changedData = try plistData(changed)
        try expect(SafariPlist.digest(changedData) != context.inputToken, "a changed file kept the same input token")
        try expect(!SafariPlist.parseBookmarks(plist).contains { ["HISTORY", "READING", "RL1"].contains($0.id) },
                   "History or Reading List entered the syncable tree")
    }

    private static func testSafariMaintenancePolicy() throws {
        var settings = SyncSettings()
        settings.bookmarkParticipatingBrowsers = [.safari, .chrome]
        try expect(!BookmarkMaintenancePolicy.allowsSafariCleanup(settings: settings), "cleanup ran with bookmark sync OFF")
        settings.enabledCategories.insert(.bookmarks)
        settings.bookmarkSyncStrategy = .twoWayMerge
        try expect(BookmarkMaintenancePolicy.allowsSafariCleanup(settings: settings), "authorized whole-library cleanup was refused")
        settings.bookmarkSyncStrategy = .oneWay
        settings.bookmarkSourceBrowser = .safari
        try expect(!BookmarkMaintenancePolicy.allowsSafariCleanup(settings: settings), "cleanup wrote the read-only one-way source")
        settings.bookmarkSyncStrategy = .twoWayMerge
        settings.bookmarkParticipatingBrowsers = [.chrome, .edge]
        try expect(!BookmarkMaintenancePolicy.allowsSafariCleanup(settings: settings), "cleanup ran while Safari does not participate")
        settings.bookmarkParticipatingBrowsers = [.safari, .chrome]
        settings.setBookmarkFolder("Bookmarks Bar/Synced", for: .safari)
        try expect(!BookmarkMaintenancePolicy.allowsSafariCleanup(settings: settings), "cleanup ran outside a selected Safari folder")
    }

    // MARK: Backup restore

    /// Safari target bound to Favorites/Synced: {A, Renamed-here}, Outside.
    private static func restoreTargetContext() throws -> (BookmarkNativeTreeContext, [String: Any]) {
        var plist = syntheticSafariPlist()
        var children = plist["Children"] as? [[String: Any]] ?? []
        for index in children.indices where children[index]["WebBookmarkUUID"] as? String == "BAR" {
            children[index]["Children"] = [
                safariFolder("SYNC", "Synced", [safariLeaf("A", "A", "https://a.test/"),
                                                safariLeaf("B", "B edited here", "https://b.test/"),
                                                safariLeaf("EXTRA", "Not in backup", "https://extra.test/")]),
                safariLeaf("OUT", "Outside", "https://out.test/")
            ]
        }
        plist["Children"] = children
        let read = SafariPlist.nativeContext(plist: plist, data: try plistData(plist), folderPath: "Bookmarks Bar/Synced")
        return (try unwrap(read.context, "restore target context failed"), plist)
    }

    /// The backup of the same folder: A, B (original title), C (deleted since).
    private static func restoreBackup() -> [Bookmark] {
        [leaf("A", "A", "https://a.test/", parent: "2", browser: .safari),
         leaf("B", "B", "https://b.test/", parent: "2", browser: .safari),
         leaf("C", "C", "https://c.test/", parent: "2", browser: .safari)]
    }

    private static func testIncrementalRestoreOnlyAdds() throws {
        let (context, plist) = try restoreTargetContext()
        let plan = BookmarkRestorePlanner.plan(desired: restoreBackup(), context: context, replacing: false)
        try expect(plan.validationError == nil, "incremental restore failed: \(plan.validationError ?? "")")
        try expect(plan.operations.count == 1 && plan.operations[0].kind == .create && plan.operations[0].title == "C",
                   "incremental restore did more than add the missing bookmark")
        let written = try unwrap(SafariPlist.applying(plan.operations, to: plist, scopeRootId: context.scopeRootId).plist,
                                 "incremental restore was not executable")
        let parsed = SafariPlist.parseBookmarks(written)
        try expect(parsed.contains { $0.id == "B" && $0.title == "B edited here" }, "incremental restore overwrote an existing title")
        try expect(parsed.contains { $0.id == "EXTRA" }, "incremental restore removed a bookmark")
        try expect(parsed.contains { $0.title == "C" && $0.parentId == "SYNC" }, "missing bookmark was not restored into the folder")
    }

    private static func testReplaceRestoreStaysInFolder() throws {
        let (context, plist) = try restoreTargetContext()
        let plan = BookmarkRestorePlanner.plan(desired: restoreBackup(), context: context, replacing: true)
        try expect(plan.validationError == nil, "replace restore failed: \(plan.validationError ?? "")")
        try expect(!plan.operations.contains { $0.kind == .removeTree && $0.id == "OUT" }, "replace restore planned a removal outside the folder")
        let written = try unwrap(SafariPlist.applying(plan.operations, to: plist, scopeRootId: context.scopeRootId).plist,
                                 "replace restore was not executable")
        let parsed = SafariPlist.parseBookmarks(written)
        let inFolder = parsed.filter { $0.parentId == "SYNC" }.map(\.title).sorted()
        try expect(inFolder == ["A", "B", "C"], "replace restore did not make the folder equal to the backup: \(inFolder)")
        try expect(parsed.contains { $0.id == "OUT" && $0.title == "Outside" }, "replace restore changed a bookmark outside the folder")
        let outsideAfter = try outsideOfSynced(written), outsideBefore = try outsideOfSynced(plist)
        try expect(outsideAfter == outsideBefore, "replace restore changed bytes outside the selected folder")
    }

    private static func testRestorePayloadDropsRoots() throws {
        let archive = [bookmark("1", "Bookmarks Bar", parent: "0", folder: true, browser: .chrome),
                       bookmark("f", "Folder", parent: "1", folder: true, browser: .chrome),
                       leaf("x", "X", "https://x.test/", parent: "f", browser: .chrome)]
        let scope = BookmarkRestorePlanner.scope(archive: archive, archiveFolder: nil, targetFolder: nil)
        let payload = BookmarkRestorePlanner.portableTree(archive: archive, scope: scope)
        try expect(!payload.contains { $0.id == "1" }, "an archived browser root became a folder to restore")
        try expect(payload.first { $0.id == "f" }?.parentId == "1", "content lost its portable bookmarks-bar role")
    }

    /// Whole-library backup: Bar/{Synced/{s1}, Other/{o1}}, Menu/{m1}.
    private static func wholeLibraryArchive() -> [Bookmark] {
        [bookmark("1", "Bookmarks Bar", parent: "0", folder: true, browser: .chrome),
         bookmark("synced", "Synced", parent: "1", folder: true, browser: .chrome),
         leaf("s1", "S1", "https://s1.test/", parent: "synced", browser: .chrome),
         bookmark("other", "Other", parent: "1", folder: true, browser: .chrome),
         leaf("o1", "O1", "https://o1.test/", parent: "other", browser: .chrome),
         bookmark("2", "Other Bookmarks", parent: "0", folder: true, browser: .chrome),
         leaf("m1", "M1", "https://m1.test/", parent: "2", browser: .chrome)]
    }

    private static func testRestoreScopeFollowsSyncFolder() throws {
        let archive = wholeLibraryArchive()
        let sub = BookmarkRestorePlanner.scope(archive: archive, archiveFolder: nil, targetFolder: "Bookmarks Bar/Synced")
        try expect(sub.isRestorable && sub.allowsReplace && sub.effectiveFolder == "Bookmarks Bar/Synced",
                   "whole-library backup into a sync folder was not scoped to that folder")
        try expect(sub.restorableIds == ["synced", "s1"], "items outside the sync folder were offered for restore: \(sub.restorableIds)")
        let payload = BookmarkRestorePlanner.portableTree(archive: archive, scope: sub)
        try expect(payload.map(\.id) == ["s1"] && payload[0].parentId == "2",
                   "restore payload was not exactly the sync folder's contents")

        let missing = BookmarkRestorePlanner.scope(archive: archive, archiveFolder: nil, targetFolder: "Bookmarks Bar/Nope")
        try expect(!missing.isRestorable && !missing.allowsReplace, "a backup without the sync folder was restorable")

        let folderArchive = BookmarkTreeMerger.extractExistingSubtreeIncludingRoot(sourceTree: archive, folderPath: "Bookmarks Bar/Synced") ?? []
        let same = BookmarkRestorePlanner.scope(archive: folderArchive, archiveFolder: "Bookmarks Bar/Synced", targetFolder: "Bookmarks Bar/Synced")
        try expect(same.isRestorable && same.allowsReplace, "same-folder backup could not be replaced")
        let moved = BookmarkRestorePlanner.scope(archive: folderArchive, archiveFolder: "Bookmarks Bar/Synced", targetFolder: "Bookmarks Bar/Other")
        try expect(moved.isRestorable && !moved.allowsReplace, "replace was allowed across different folders")
        let backToWhole = BookmarkRestorePlanner.scope(archive: folderArchive, archiveFolder: "Bookmarks Bar/Synced", targetFolder: nil)
        try expect(backToWhole.effectiveFolder == "Bookmarks Bar/Synced" && backToWhole.allowsReplace,
                   "a folder backup restored into a whole-library browser was not bound to its own folder")
    }

    private static func testFolderBackupKeepsAncestors() throws {
        // Bar/Work/Synced/{s1}, plus siblings that must not be archived.
        let tree = [bookmark("1", "Bookmarks Bar", parent: "0", folder: true, browser: .chrome),
                    bookmark("work", "Work", parent: "1", folder: true, browser: .chrome),
                    leaf("w1", "Work sibling", "https://w1.test/", parent: "work", browser: .chrome),
                    bookmark("synced", "Synced", parent: "work", folder: true, browser: .chrome),
                    leaf("s1", "S1", "https://s1.test/", parent: "synced", browser: .chrome),
                    leaf("b1", "Bar sibling", "https://b1.test/", parent: "1", browser: .chrome)]
        let path = "Bookmarks Bar/Work/Synced"
        let archive = try unwrap(BookmarkTreeMerger.extractExistingSubtreeWithAncestors(sourceTree: tree, folderPath: path),
                                 "nested folder could not be archived")
        try expect(Set(archive.map(\.id)) == ["1", "work", "synced", "s1"], "archive missed the ancestor chain or included siblings")
        let scope = BookmarkRestorePlanner.scope(archive: archive, archiveFolder: path, targetFolder: path)
        try expect(scope.isRestorable && scope.allowsReplace && scope.restorableIds == ["synced", "s1"],
                   "a nested folder backup was not restorable from its ancestor chain")

        // Backups taken before ancestor chains were stored still restore.
        let legacy = BookmarkTreeMerger.extractExistingSubtreeIncludingRoot(sourceTree: tree, folderPath: path) ?? []
        try expect(!legacy.contains { $0.id == "work" }, "fixture is not a legacy archive")
        let legacyScope = BookmarkRestorePlanner.scope(archive: legacy, archiveFolder: path, targetFolder: path)
        try expect(legacyScope.isRestorable && legacyScope.restorableIds == ["synced", "s1"], "a legacy folder backup became unrestorable")

        // Native target archives use portable roots so the path resolves.
        let native = [bookmark("toolbar_____", "Bookmarks Toolbar", parent: "root________", folder: true, browser: .firefox),
                      bookmark("fw", "Work", parent: "toolbar_____", folder: true, browser: .firefox),
                      bookmark("fs", "Synced", parent: "fw", folder: true, browser: .firefox),
                      leaf("fs1", "S1", "https://s1.test/", parent: "fs", browser: .firefox),
                      leaf("fo", "Outside", "https://out.test/", parent: "toolbar_____", browser: .firefox)]
        let context = BookmarkNativeTreeContext(inputToken: "t", browser: .firefox, nodes: native,
                                                rootIds: ["1": "toolbar_____"], sourceToNativeIds: [:], scopeRootId: "fs")
        let nativeArchive = BookmarkRestorePlanner.archive(of: context)
        try expect(Set(nativeArchive.map(\.id)) == ["1", "fw", "fs", "fs1"], "native archive was not scoped to the folder and its ancestors")
        try expect(BookmarkTreeMerger.folderId(tree: nativeArchive, folderPath: path) == "fs", "native archive path did not resolve")
    }

    private static func testFirefoxArchiveRoots() throws {
        let archive = [bookmark("firefox-toolbar-root", "Bookmarks Toolbar", parent: "0", folder: true, browser: .firefox),
                       bookmark("firefox-menu-root", "Bookmarks Menu", parent: "0", folder: true, browser: .firefox),
                       bookmark("firefox-other-root", "Other Bookmarks", parent: "0", folder: true, browser: .firefox),
                       bookmark("firefox-mobile-root", "Mobile Bookmarks", parent: "0", folder: true, browser: .firefox),
                       leaf("t1", "T1", "https://t1.test/", parent: "1", browser: .firefox),
                       leaf("o1", "O1", "https://o1.test/", parent: "2", browser: .firefox)]
        let scope = BookmarkRestorePlanner.scope(archive: archive, archiveFolder: nil, targetFolder: nil)
        let payload = BookmarkRestorePlanner.portableTree(archive: archive, scope: scope)
        try expect(Set(payload.map(\.id)) == ["t1", "o1"], "Firefox root placeholders were restored as folders: \(payload.map(\.id))")
        let target = BookmarkNativeTreeContext(
            inputToken: "t", browser: .firefox,
            nodes: [bookmark("toolbar_____", "Bookmarks Toolbar", parent: "root________", folder: true, browser: .firefox),
                    bookmark("unfiled_____", "Other Bookmarks", parent: "root________", folder: true, browser: .firefox)],
            rootIds: ["1": "toolbar_____", "2": "unfiled_____", "3": "unfiled_____"], sourceToNativeIds: [:], scopeRootId: nil)
        let plan = BookmarkRestorePlanner.plan(desired: payload, context: target, replacing: true)
        try expect(plan.validationError == nil, "Firefox restore failed: \(plan.validationError ?? "")")
        try expect(!plan.operations.contains { $0.parentId == "0" }, "a restore operation targeted the tree root")
        try expect(Set(plan.operations.compactMap(\.parentId)) == ["toolbar_____", "unfiled_____"], "Firefox content was not placed in its native roots")
    }

    private static func testPlannerRefusesUnknownParent() throws {
        let target = context(.chrome, [])
        let orphan = [bookmark("root-like", "Root-like", parent: "0", folder: true, browser: .safari),
                      leaf("child", "Child", "https://child.test/", parent: "root-like", browser: .safari)]
        let plan = NativeBookmarkPlanner.makePlan(desired: orphan, context: target, fullMirror: true)
        try expect(plan.validationError != nil && plan.operations.isEmpty,
                   "a plan creating under a parent outside the target tree was executable")
    }

    private static func testRestoreIgnoresForeignIdMap() throws {
        var target = context(.chrome, [leaf("55", "Unrelated", "https://unrelated.test/", parent: "chrome-other", browser: .chrome)])
        target.sourceToNativeIds = ["30": "55"]   // e.g. an Edge ID mapped in Chrome's syncIdMap
        let backup = [leaf("30", "Restored", "https://restored.test/", parent: "2", browser: .chrome)]
        for replacing in [false, true] {
            let plan = BookmarkRestorePlanner.plan(desired: backup, context: target, replacing: replacing)
            try expect(plan.validationError == nil, "restore failed: \(plan.validationError ?? "")")
            try expect(!plan.operations.contains { $0.id == "55" && $0.kind == .update },
                       "a colliding syncIdMap entry overwrote an unrelated bookmark (replacing: \(replacing))")
            try expect(plan.operations.contains { $0.kind == .create && $0.title == "Restored" },
                       "the archived bookmark was not restored (replacing: \(replacing))")
        }
    }

    private static func testIncrementalRestoreSameTitleElsewhere() throws {
        let target = context(.chrome, [
            bookmark("work", "Work", parent: "chrome-other", folder: true, browser: .chrome),
            leaf("wd", "Docs", "https://work-docs.test/", parent: "work", browser: .chrome),
            bookmark("home", "Home", parent: "chrome-other", folder: true, browser: .chrome)])
        let backup = [bookmark("bh", "Home", parent: "2", folder: true, browser: .chrome),
                      leaf("hd", "Docs", "https://home-docs.test/", parent: "bh", browser: .chrome)]
        let plan = BookmarkRestorePlanner.plan(desired: backup, context: target, replacing: false)
        try expect(plan.validationError == nil, "restore failed: \(plan.validationError ?? "")")
        try expect(plan.operations.contains { $0.kind == .create && $0.title == "Docs" && $0.parentId == "home" },
                   "a bookmark sharing a title with one in another folder was silently skipped")
        try expect(!plan.operations.contains { $0.id == "wd" }, "incremental restore touched the unrelated bookmark")
    }

    private static func testContextScopeBinding() throws {
        var scoped = context(.firefox, [bookmark("fs", "Synced", parent: "firefox-bar", folder: true, browser: .firefox)])
        scoped.scopeRootId = "fs"
        try expect(BookmarkRestorePlanner.contextMatchesRequestedScope(scoped, requestedFolder: "Bookmarks Bar/Synced"), "a correctly bound tree was refused")
        try expect(!BookmarkRestorePlanner.contextMatchesRequestedScope(scoped, requestedFolder: nil), "a scoped tree was accepted for a whole-library request")
        var unbound = scoped; unbound.scopeRootId = nil
        try expect(!BookmarkRestorePlanner.contextMatchesRequestedScope(unbound, requestedFolder: "Bookmarks Bar/Synced"),
                   "a tree without the requested folder scope was accepted")
        var invisible = scoped; invisible.scopeRootId = "menu-folder-not-in-nodes"
        try expect(!BookmarkRestorePlanner.contextMatchesRequestedScope(invisible, requestedFolder: "Bookmarks Menu/Synced"),
                   "a scope node missing from the reported tree was accepted")
        try expect(BookmarkRestorePlanner.contextMatchesRequestedScope(unbound, requestedFolder: nil), "an unscoped whole-library tree was refused")
    }
}
