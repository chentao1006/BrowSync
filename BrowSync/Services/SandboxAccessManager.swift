import Foundation
import AppKit
import OSLog

@MainActor
final class SandboxAccessManager: ObservableObject {
    static let shared = SandboxAccessManager()
    
    private let defaultsKey = "SafariSandboxBookmarkData"
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SandboxAccessManager")
    
    @Published var hasSafariAccess: Bool = false
    
    private init() {
        checkAccess()
    }
    
    private func checkAccess() {
        hasSafariAccess = UserDefaults.standard.data(forKey: defaultsKey) != nil
    }
    
    func requestSafariAccess(completion: @escaping (Bool) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.message = String(localized: "Please select the Safari folder to grant BrowSync access for syncing.", bundle: LanguageBundle.systemBundle)
        openPanel.prompt = String(localized: "Grant Access", bundle: LanguageBundle.systemBundle)
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false
        
        let expectedURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")
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
                DispatchQueue.main.async {
                    self.hasSafariAccess = true
                }
                self.logger.notice("Successfully acquired and saved Security-Scoped Bookmark for Safari.")
                completion(true)
            } catch {
                self.logger.error("Failed to create bookmark data: \(error.localizedDescription)")
                completion(false)
            }
        }
    }
    
    /// Wraps a block of code with temporary access to the Safari folder.
    func withSafariAccess<T>(_ block: () throws -> T) rethrows -> T {
#if APP_STORE
        guard let bookmarkData = UserDefaults.standard.data(forKey: defaultsKey) else {
            return try block()
        }
        
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return try block()
        }
        
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try block()
#else
        return try block()
#endif
    }
}
