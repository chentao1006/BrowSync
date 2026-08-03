import Foundation
import Aptabase

@MainActor
final class AnalyticsManager {
    static let shared = AnalyticsManager()
    private static let lastDailyHeartbeatDateKey = "lastDailyHeartbeatDate"
    private var isInitialized = false
    private var dailyHeartbeatTimer: Timer?
    
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

        scheduleDailyHeartbeat()
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

    /// Sends a lightweight daily liveness event independently from optional usage analytics.
    private func scheduleDailyHeartbeat() {
        dailyHeartbeatTimer?.invalidate()

        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        guard let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return
        }

        dailyHeartbeatTimer = Timer(fire: nextMidnight, interval: 0, repeats: false) { [weak self] _ in
            self?.sendDailyHeartbeat()
        }
        RunLoop.main.add(dailyHeartbeatTimer!, forMode: .common)
    }

    private func sendDailyHeartbeat() {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let lastHeartbeat = UserDefaults.standard.object(forKey: Self.lastDailyHeartbeatDateKey) as? Date

        if lastHeartbeat.map({ calendar.isDate($0, inSameDayAs: today) }) != true {
            Aptabase.shared.trackEvent("Daily Heartbeat")
            Aptabase.shared.flush()
            UserDefaults.standard.set(today, forKey: Self.lastDailyHeartbeatDateKey)
        }

        scheduleDailyHeartbeat()
    }
}
