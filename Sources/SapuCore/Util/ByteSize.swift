import Foundation

public enum ByteSize {
    /// Formats with decimal units (1 GB = 1,000,000,000 bytes), the same way Finder does.
    public static func format(_ bytes: Int64) -> String {
        let negative = bytes < 0
        var value = Double(bytes.magnitude)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let text: String
        if unit == 0 {
            text = "\(Int(value)) B"
        } else if value >= 99.95 {
            text = String(format: "%.0f", value) + " " + units[unit]
        } else if value >= 9.995 {
            text = String(format: "%.1f", value) + " " + units[unit]
        } else {
            text = String(format: "%.2f", value) + " " + units[unit]
        }
        return negative ? "-" + text : text
    }

    /// Parses sizes such as `500k`, `10M`, `1.5GB`, `2GiB` or plain bytes.
    /// K/M/G/T are decimal; KiB/MiB/GiB/TiB are binary.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let numberEnd = trimmed.firstIndex { !($0.isNumber || $0 == ".") } ?? trimmed.endIndex
        guard let number = Double(trimmed[..<numberEnd]), number >= 0 else { return nil }
        let suffix = trimmed[numberEnd...].trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch suffix {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1e3
        case "m", "mb": multiplier = 1e6
        case "g", "gb": multiplier = 1e9
        case "t", "tb": multiplier = 1e12
        case "kib": multiplier = 1024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        let result = number * multiplier
        guard result < 9e18 else { return nil }
        return Int64(result)
    }
}

public enum DurationText {
    /// Parses ages such as `12h`, `30d`, `2w`, `6m` (months) or `1y` into seconds.
    public static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let number = Double(trimmed.dropLast()), number >= 0 else { return nil }
        switch unit {
        case "h": return number * 3600
        case "d": return number * 86400
        case "w": return number * 86400 * 7
        case "m": return number * 86400 * 30
        case "y": return number * 86400 * 365
        default: return nil
        }
    }

    /// "3 days ago", "8 months ago".
    public static func ago(_ seconds: TimeInterval) -> String {
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        let s = max(0, seconds)
        if s < 3600 { return "just now" }
        if s < 86400 { return plural(Int(s / 3600), "hour") }
        if s < 86400 * 60 { return plural(Int(s / 86400), "day") }
        if s < 86400 * 365 * 2 { return plural(Int(s / (86400 * 30)), "month") }
        return plural(Int(s / (86400 * 365)), "year")
    }
}
