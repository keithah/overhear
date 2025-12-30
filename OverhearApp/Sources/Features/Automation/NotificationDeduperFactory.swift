import Foundation

enum NotificationDeduperFactory {
    static func makeFromDefaults() -> NotificationDeduper {
        let defaults = UserDefaults.standard
        let ttl = defaults.double(forKey: UserDefaultsKeys.notificationDeduperTTL)
        let cleanup = defaults.double(forKey: UserDefaultsKeys.notificationDeduperCleanupInterval)
        let maxTTL: TimeInterval = 24 * 60 * 60
        let clampedTTL = ttl > 0 ? min(max(1, ttl), maxTTL) : 60 * 60
        // Faster cleanup in DEBUG to make tests deterministic; production defaults to 10 minutes.
        #if DEBUG
        let defaultCleanup: TimeInterval = 120
        #else
        let defaultCleanup: TimeInterval = 600
        #endif
        let clampedCleanup = cleanup > 0 ? min(max(30, cleanup), maxTTL) : defaultCleanup
        return NotificationDeduper(
            maxEntries: 200,
            ttl: clampedTTL,
            cleanupInterval: clampedCleanup
        )
    }
}
