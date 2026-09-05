import Foundation
import AppKit
import OSLog

@MainActor
final class SandboxAccessManager: ObservableObject {
    static let shared = SandboxAccessManager()
    
    private let defaultsKey = "SafariSandboxBookmarkData"
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SandboxAccessManager")
    private var isPresentingUpgradeAccessPrompt = false
    
    @Published var hasSafariAccess: Bool = false
    
    private init() {
        checkAccess()
    }
    
    private func checkAccess() {
        guard let url = resolveSafariDirectoryURL() else {
            hasSafariAccess = false
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard accessed else {
            invalidateSafariAccess("saved bookmark no longer grants access")
            return
        }
        hasSafariAccess = true
    }
    
    func requestSafariAccess(completion: @escaping (Bool) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.message = String(localized: "Please select the Safari folder to grant BrowSync access for syncing.", bundle: LanguageBundle.systemBundle)
        openPanel.prompt = String(localized: "Grant Access", bundle: LanguageBundle.systemBundle)
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false
        
        // In a sandbox, NSHomeDirectory() resolves to the app container.
        // Start the picker at the real user's Safari directory instead.
        let expectedURL = NSHomeDirectoryForUser(NSUserName())
            .map { URL(fileURLWithPath: $0).appendingPathComponent("Library/Safari") }
        openPanel.directoryURL = expectedURL
        
        openPanel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = openPanel.url else {
                completion(false)
                return
            }
            
            // Verify it's actually the Safari folder
            guard url.lastPathComponent == "Safari" else {
                self.logger.error("User selected incorrect folder: \(url.path)")
                completion(false)
                return
            }
            
            do {
                let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmarkData, forKey: self.defaultsKey)
                self.checkAccess()
                if self.hasSafariAccess {
                    self.logger.notice("Successfully acquired and validated Security-Scoped Bookmark for Safari.")
                    completion(true)
                } else {
                    completion(false)
                }
            } catch {
                self.logger.error("Failed to create bookmark data: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    /// A direct-install upgrade can preserve the user's sync settings, but its
    /// old Full Disk Access grant cannot be converted into a security-scoped
    /// bookmark. Prompt only when the migrated settings actually require Safari
    /// bookmark access, so new users and users without Safari bookmark sync are
    /// never interrupted.
    func promptForSafariAccessAfterUpgradeIfNeeded(
        syncSettings: SyncSettings,
        onGranted: @escaping () -> Void
    ) {
        guard !hasSafariAccess,
              !isPresentingUpgradeAccessPrompt,
              syncSettings.enabledCategories.contains(.bookmarks),
              syncSettings.bookmarkParticipatingBrowsers.contains(.safari) else {
            return
        }

        isPresentingUpgradeAccessPrompt = true
        let alert = NSAlert()
        alert.messageText = String(localized: "Safari Bookmark Permission Required", bundle: LanguageBundle.systemBundle)
        alert.informativeText = String(localized: "BrowSync now uses limited folder access instead of Full Disk Access. To keep your existing Safari bookmark sync running, select the Safari folder in the next dialog.", bundle: LanguageBundle.systemBundle)
        alert.addButton(withTitle: String(localized: "Grant Access", bundle: LanguageBundle.systemBundle))
        alert.addButton(withTitle: String(localized: "Not Now", bundle: LanguageBundle.systemBundle))

        NSApp.activate(ignoringOtherApps: true)
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.isPresentingUpgradeAccessPrompt = false
                return
            }
            self.requestSafariAccess { granted in
                if granted {
                    onGranted()
                }
                self.isPresentingUpgradeAccessPrompt = false
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
    
    /// Wraps a block of code with temporary access to the user-selected Safari folder.
    /// The direct and App Store builds intentionally share this path so neither needs
    /// system-wide file access to read Safari bookmarks.
    func withSafariAccess<T>(_ block: () throws -> T) rethrows -> T {
        guard let url = resolveSafariDirectoryURL() else {
            logger.warning("withSafariAccess: no valid saved bookmark data")
            return try block()
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard accessed else {
            invalidateSafariAccess("saved bookmark did not start a security scope")
            return try block()
        }
        hasSafariAccess = true
        
        // Cache the resolved URL so callers can build paths relative to it.
        // Save/restore rather than unconditionally clearing, so a nested call
        // (or an outer call still in flight) doesn't lose its cached URL when
        // this inner call returns.
        let previousResolvedURL = _resolvedSafariDirectoryURL
        _resolvedSafariDirectoryURL = url
        defer { _resolvedSafariDirectoryURL = previousResolvedURL }

        return try block()
    }

    /// Resolves the saved bookmark and refreshes it if macOS reports it stale.
    /// Resolution alone does not establish access; callers must still use
    /// `startAccessingSecurityScopedResource()` before touching Safari files.
    private func resolveSafariDirectoryURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            invalidateSafariAccess("saved bookmark could not be resolved")
            return nil
        }

        if isStale {
            logger.notice("Safari security-scoped bookmark is stale, attempting to refresh")
            if let freshData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(freshData, forKey: defaultsKey)
                logger.notice("Safari security-scoped bookmark refreshed successfully")
            } else {
                invalidateSafariAccess("stale bookmark could not be refreshed")
                return nil
            }
        }
        return url
    }

    private func invalidateSafariAccess(_ reason: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        hasSafariAccess = false
        logger.warning("Safari folder access invalidated: \(reason)")
    }
    
    /// Only valid while inside a `withSafariAccess` closure.
    /// Returns the security-scoped Safari directory URL so callers can construct
    /// the real path to Bookmarks.plist instead of using homeDirectoryForCurrentUser.
    private(set) var _resolvedSafariDirectoryURL: URL? = nil
    
    var safariBookmarksPlistURL: URL? {
        // Inside withSafariAccess, _resolvedSafariDirectoryURL is the real ~/Library/Safari
        if let safariDir = _resolvedSafariDirectoryURL {
            let url = safariDir.appendingPathComponent("Bookmarks.plist")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }
}
