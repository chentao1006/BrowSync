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
            ("folder-to-folder creates no system wrappers", testSelectedFolderToSelectedFolder)
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
}
