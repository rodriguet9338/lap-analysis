import Foundation

/// One logged channel. Each channel keeps its own time base because AiM
/// loggers sample channels at different rates (GPS 10-25 Hz, IMU 50-100 Hz).
public struct Channel: Sendable, Equatable {
    public var name: String
    public var units: String
    /// Decimal places the logger suggests for display.
    public var decimals: Int
    /// false for step channels (gear, lap diffs) that must be forward-filled
    /// rather than linearly interpolated.
    public var interpolate: Bool
    /// Seconds since session start, strictly non-decreasing. Same count as `values`.
    public var times: [Double]
    public var values: [Double]

    public init(name: String, units: String = "", decimals: Int = 2,
                interpolate: Bool = true, times: [Double] = [], values: [Double] = []) {
        self.name = name
        self.units = units
        self.decimals = decimals
        self.interpolate = interpolate
        self.times = times
        self.values = values
    }

    /// Value at time `t` (seconds since session start), interpolated or
    /// forward-filled per `interpolate`. Clamps outside the sampled range.
    /// Returns nil for an empty channel.
    public func value(at t: Double) -> Double? {
        guard !times.isEmpty else { return nil }
        if t <= times[0] { return values[0] }
        if t >= times[times.count - 1] { return values[values.count - 1] }
        // Binary search for the first sample with time > t.
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        guard interpolate else { return values[lo] }
        let span = times[hi] - times[lo]
        guard span > 0 else { return values[lo] }
        let f = (t - times[lo]) / span
        return values[lo] + f * (values[hi] - values[lo])
    }
}

/// A lap as recorded by the logger (beacon / GPS start-finish crossing).
public struct Lap: Sendable, Equatable, Identifiable {
    public var number: Int
    /// Seconds since session start.
    public var start: Double
    public var end: Double

    public var id: Int { number }
    public var duration: Double { end - start }

    public init(number: Int, start: Double, end: Double) {
        self.number = number
        self.start = start
        self.end = end
    }
}

public struct SessionMetadata: Sendable, Equatable {
    public var driver: String = ""
    public var vehicle: String = ""
    public var venue: String = ""
    public var deviceName: String = ""
    public var loggerID: String = ""
    /// Wall-clock start of the log, if the file carries one.
    public var date: Date?
    /// Everything else the file header carries, verbatim.
    public var extra: [String: String] = [:]

    public init() {}
}

/// A fully decoded logger session, independent of the file format it came from.
public struct Session: Sendable, Equatable {
    public var metadata: SessionMetadata
    /// Channels in file order.
    public var channels: [Channel]
    public var laps: [Lap]

    public init(metadata: SessionMetadata = .init(), channels: [Channel] = [], laps: [Lap] = []) {
        self.metadata = metadata
        self.channels = channels
        self.laps = laps
    }

    public func channel(_ name: String) -> Channel? {
        channels.first { $0.name == name }
    }

    /// Fastest lap excluding the first (out) and last (in) lap when there are
    /// at least three laps; otherwise the fastest of what exists.
    public var bestLap: Lap? {
        let candidates = laps.count >= 3 ? Array(laps.dropFirst().dropLast()) : laps
        return candidates.min { $0.duration < $1.duration }
    }
}

/// Canonical channel names emitted by the XRK parser (matching libxrk).
public enum ChannelName {
    public static let gpsSpeed = "GPS Speed"          // m/s
    public static let gpsLatitude = "GPS Latitude"    // degrees
    public static let gpsLongitude = "GPS Longitude"  // degrees
    public static let gpsAltitude = "GPS Altitude"    // m
}
