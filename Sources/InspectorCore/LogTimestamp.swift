import Foundation

/// Helpers for oMLX log timestamps, which look like `2026-11-27 10:00:00,123`.
public enum LogTimestamp {
    /// The time of day in a log timestamp: `HH:mm:ss`, or `HH:mm` without seconds.
    /// Returns an empty string for an empty timestamp (unframed or partial records).
    public static func timeOfDay(_ timestamp: String, includingSeconds: Bool = true) -> String {
        String(timestamp.dropFirst("yyyy-MM-dd ".count).prefix(includingSeconds ? 8 : 5))
    }
}
