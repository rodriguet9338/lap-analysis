import Foundation

public enum LapResampler {
    /// Distance = cumulative integral of GPS Speed over time within the lap.
    public static func trace(session: Session, lap: Lap, step: Double = 1.0,
                             label: String? = nil) -> LapTrace? {
        guard step > 0, step.isFinite else { return nil }
        guard lap.end > lap.start else { return nil }
        guard let speed = session.channel(ChannelName.gpsSpeed) else { return nil }

        // Raw samples inside the lap.
        let sampleCount: Int = Swift.min(speed.times.count, speed.values.count)
        var inside: Int = 0
        var ts: [Double] = [lap.start]
        var vs: [Double] = [Swift.max(0, speed.value(at: lap.start) ?? 0)]
        for i in 0..<sampleCount {
            let t: Double = speed.times[i]
            if t >= lap.start && t <= lap.end {
                inside += 1
                if t > lap.start && t < lap.end {
                    ts.append(t)
                    let v: Double = speed.values[i]
                    vs.append(v.isFinite ? Swift.max(0, v) : 0)
                }
            }
        }
        if inside < 2 { return nil }
        ts.append(lap.end)
        vs.append(Swift.max(0, speed.value(at: lap.end) ?? 0))

        // Cumulative distance (trapezoid rule).
        var cum: [Double] = [0]
        for k in 1..<ts.count {
            let dt: Double = ts[k] - ts[k - 1]
            cum.append(cum[k - 1] + 0.5 * (vs[k - 1] + vs[k]) * dt)
        }
        let total: Double = cum[cum.count - 1]
        guard total.isFinite, total >= step else { return nil }

        // Invert onto a uniform distance grid.
        let gridCount: Int = Int((total / step + 1e-9).rounded(.down))
        var distance: [Double] = []
        var time: [Double] = []
        distance.reserveCapacity(gridCount + 1)
        time.reserveCapacity(gridCount + 1)
        var j: Int = 1
        for i in 0...gridCount {
            let d: Double = Double(i) * step
            distance.append(d)
            if d <= 0 {
                time.append(0)
                continue
            }
            while j < cum.count - 1 && cum[j] < d { j += 1 }
            var t: Double
            if cum[j] < d {
                t = ts[j]
            } else {
                let dc: Double = cum[j] - cum[j - 1]
                if dc > 0 {
                    t = ts[j - 1] + (d - cum[j - 1]) / dc * (ts[j] - ts[j - 1])
                } else {
                    t = ts[j - 1]
                }
            }
            t -= lap.start
            if let prev = time.last, t < prev { t = prev }
            time.append(t)
        }

        // Positions and all session channels at the grid's session times.
        let latChannel: Channel? = session.channel(ChannelName.gpsLatitude)
        let lonChannel: Channel? = session.channel(ChannelName.gpsLongitude)
        var lat: [Double] = []
        var lon: [Double] = []
        lat.reserveCapacity(time.count)
        lon.reserveCapacity(time.count)
        for t in time {
            let s: Double = lap.start + t
            lat.append(latChannel?.value(at: s) ?? Double.nan)
            lon.append(lonChannel?.value(at: s) ?? Double.nan)
        }
        var channels: [String: [Double]] = [:]
        for ch in session.channels {
            var arr: [Double] = []
            arr.reserveCapacity(time.count)
            for t in time {
                arr.append(ch.value(at: lap.start + t) ?? Double.nan)
            }
            channels[ch.name] = arr
        }

        let resolvedLabel: String = label ?? defaultLabel(for: lap)
        return LapTrace(label: resolvedLabel, lap: lap, step: step,
                        distance: distance, time: time,
                        latitude: lat, longitude: lon,
                        channels: channels, length: total)
    }

    /// "L<number> <m:ss.mmm>"
    static func defaultLabel(for lap: Lap) -> String {
        let totalMs: Int = Int((Swift.max(0, lap.duration) * 1000).rounded())
        let minutes: Int = totalMs / 60000
        let seconds: Int = (totalMs / 1000) % 60
        let millis: Int = totalMs % 1000
        return "L\(lap.number) " + String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }
}
