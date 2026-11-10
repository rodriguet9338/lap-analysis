import Foundation

/// One lap resampled onto a uniform distance grid, so laps can be overlaid.
public struct LapTrace: Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var lap: Lap
    /// Metres between grid points.
    public var step: Double
    /// 0, step, 2*step ... (metres from lap start).
    public var distance: [Double]
    /// Seconds since lap start at each grid point.
    public var time: [Double]
    public var latitude: [Double]
    public var longitude: [Double]
    /// Every session channel, sampled at the grid.
    public var channels: [String: [Double]]
    /// Full integrated lap distance in metres (may exceed the last grid point).
    public var totalLength: Double

    /// Total lap distance in metres.
    public var length: Double { totalLength }

    /// `length` defaults to the last grid distance when omitted.
    public init(id: UUID = UUID(),
                label: String,
                lap: Lap,
                step: Double,
                distance: [Double],
                time: [Double],
                latitude: [Double],
                longitude: [Double],
                channels: [String: [Double]],
                length: Double? = nil) {
        self.id = id
        self.label = label
        self.lap = lap
        self.step = step
        self.distance = distance
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.channels = channels
        self.totalLength = length ?? (distance.last ?? 0)
    }
}
