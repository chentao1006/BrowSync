import Foundation
import Aptabase

@MainActor
final class AnalyticsManager {
    static let shared = AnalyticsManager()
    private var isInitialized = false
    
    private init() {}
    
    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true

        // We initialize Aptabase. It doesn't send events unless trackEvent is called.
        Aptabase.shared.initialize(appKey: "A-US-7527250881")
        
        let settings = AppState.shared.settingsService.general
        if settings.analyticsEnabled {
            trackEvent("App Started")
        }
    }
    
    func trackEvent(_ eventName: String, props: [String: Any]? = nil) {
        let settings = AppState.shared.settingsService.general
        guard settings.analyticsEnabled else { return }
        
        if let props = props {
            var aptabaseProps: [String: Value] = [:]
            for (k, v) in props {
                if let str = v as? String { aptabaseProps[k] = str }
                else if let int = v as? Int { aptabaseProps[k] = int }
                else if let double = v as? Double { aptabaseProps[k] = double }
                else if let bool = v as? Bool { aptabaseProps[k] = bool }
                else { aptabaseProps[k] = String(describing: v) }
            }
            Aptabase.shared.trackEvent(eventName, with: aptabaseProps)
        } else {
            Aptabase.shared.trackEvent(eventName)
        }

        // The SDK normally flushes on its active-state timer, but menu-bar apps
        // can initialize after that notification has already fired.
        Aptabase.shared.flush()
    }
}
