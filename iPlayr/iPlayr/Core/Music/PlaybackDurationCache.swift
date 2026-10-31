import Foundation

/// Persistent cache of track durations keyed by MusicKit song ID.
///
/// MusicKit occasionally reports a zero duration for downloaded, DRM-protected
/// library items. The exact duration is fetched once from the catalog and kept
/// here, so the Now Playing progress bar keeps working on later launches —
/// including offline ones.
enum PlaybackDurationCache {
    static let defaultsKey = "playbackDurationCache"
    private static let unmatchedKey = "durationUnmatchedSongIDs"

    private static let queue = DispatchQueue(label: "com.brunocastello.iPlayr.durationCache")

    static func all() -> [String: TimeInterval] {
        queue.sync {
            storedDurations().compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
    }

    static func duration(for id: String) -> TimeInterval? {
        queue.sync {
            (storedDurations()[id] as? NSNumber)?.doubleValue
        }
    }

    static func set(_ duration: TimeInterval, for id: String) {
        guard duration > 0 else { return }
        queue.sync {
            var stored = storedDurations()
            stored[id] = duration
            UserDefaults.standard.set(stored, forKey: defaultsKey)
            removeUnmatched(id)
        }
    }

    static func set(_ durations: [String: TimeInterval]) {
        guard !durations.isEmpty else { return }
        queue.sync {
            var stored = storedDurations()
            for (id, duration) in durations where duration > 0 {
                stored[id] = duration
                removeUnmatched(id)
            }
            UserDefaults.standard.set(stored, forKey: defaultsKey)
        }
    }

    static func unmatchedIDs() -> Set<String> {
        queue.sync { Set(UserDefaults.standard.stringArray(forKey: unmatchedKey) ?? []) }
    }

    static func markUnmatched(_ id: String) {
        queue.sync {
            var ids = Set(UserDefaults.standard.stringArray(forKey: unmatchedKey) ?? [])
            ids.insert(id)
            UserDefaults.standard.set(Array(ids), forKey: unmatchedKey)
        }
    }

    static func clearUnmatched() {
        queue.sync {
            UserDefaults.standard.removeObject(forKey: unmatchedKey)
        }
    }

    private static func removeUnmatched(_ id: String) {
        guard var ids = UserDefaults.standard.stringArray(forKey: unmatchedKey), ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        UserDefaults.standard.set(ids, forKey: unmatchedKey)
    }

    private static func storedDurations() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
    }
}
