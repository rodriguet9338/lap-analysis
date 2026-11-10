import Foundation

/// Speed unit shown in the UI. The model always stores speed in m/s.
enum SpeedUnit: String, CaseIterable, Identifiable {
    case mph
    case kmh

    var id: String { rawValue }
    var label: String { self == .mph ? "mph" : "km/h" }
    /// Multiplier from m/s.
    var factorFromMetersPerSecond: Double { self == .mph ? 2.2369362921 : 3.6 }
}

/// Small, dependency-free formatting helpers.
enum Fmt {
    /// m:ss.mmm (e.g. 1:58.690). Non-finite input renders as "–".
    static func lapTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let negative: Bool = seconds < 0
        let totalMs: Int = Int((abs(seconds) * 1000.0).rounded())
        let minutes: Int = totalMs / 60000
        let secs: Int = (totalMs / 1000) % 60
        let ms: Int = totalMs % 1000
        let body: String = String(format: "%d:%02d.%03d", minutes, secs, ms)
        return negative ? "-" + body : body
    }

    /// Signed delta with three decimals (+0.000 / -0.123).
    static func delta(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let rounded: Double = (seconds * 1000.0).rounded() / 1000.0
        if rounded == 0 { return "+0.000" }
        return String(format: "%+.3f", rounded)
    }

    /// Split time: "23.456" under a minute, otherwise m:ss.mmm.
    static func splitTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        if seconds >= 60 { return lapTime(seconds) }
        return String(format: "%.3f", seconds)
    }

    static func distance(_ meters: Double) -> String {
        guard meters.isFinite else { return "–" }
        return String(format: "%.0f m", meters)
    }

    static func value(_ v: Double?, decimals: Int = 1) -> String {
        guard let v = v, v.isFinite else { return "–" }
        return String(format: "%.\(decimals)f", v)
    }
}
