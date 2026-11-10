# Architecture

One Swift package, three targets.

| Target | Role | May import |
| --- | --- | --- |
| `LapCore` | File parsing, lap maths, device protocol | Foundation, Compression, Network only |
| `LapAnalysisApp` | macOS SwiftUI app (iOS later) | LapCore, SwiftUI, Charts |
| `LapCoreTests` | XCTest, golden fixtures | LapCore |

`LapCore` must stay free of UI frameworks so the same code backs the iOS app.

## Data flow

```
.xrk/.xrz file ──XRKParser──▶ Session ──LapResampler──▶ LapTrace ──▶ Delta / Splits / Histogram ──▶ views
Solo 2 Wi-Fi ──AiMDevice (planned)──▶ .xrk bytes ─┘
```

## Public contract of LapCore

`Model/Session.swift` (already written, do not change signatures): `Channel`, `Lap`,
`SessionMetadata`, `Session`, `ChannelName`.

### XRK (`Sources/LapCore/XRK/`)

```swift
public enum XRKError: Error { case notXRK, truncated, decompressionFailed, malformed(String) }
public enum XRKParser {
    /// Accepts .xrk or .xrz bytes (xrz = zlib-compressed xrk, detected by content).
    public static func parse(_ data: Data) throws -> Session
    public static func parse(contentsOf url: URL) throws -> Session
}
```

Port of libxrk (MIT, m3rlin45/libxrk). Times are converted from milliseconds to
seconds. Channel names and units must match libxrk's output.

### Analysis (`Sources/LapCore/Analysis/`)

```swift
/// One lap resampled onto a uniform distance grid, so laps can be overlaid.
public struct LapTrace: Sendable, Identifiable {
    public let id: UUID
    public var label: String            // e.g. "Thomas – L4 1:58.69"
    public var lap: Lap
    public var step: Double             // metres between grid points
    public var distance: [Double]       // 0, step, 2*step ... (metres from lap start)
    public var time: [Double]           // seconds since lap start at each grid point
    public var latitude: [Double]
    public var longitude: [Double]
    public var channels: [String: [Double]]   // every session channel, sampled at the grid
    public var length: Double { get }   // total lap distance in metres
}

public enum LapResampler {
    /// Distance = cumulative integral of GPS Speed over time within the lap.
    public static func trace(session: Session, lap: Lap, step: Double = 1.0,
                             label: String? = nil) -> LapTrace?   // nil if no GPS speed
}

public enum LapDelta {
    /// time(lap) - time(reference) at each of the reference's grid points.
    /// The compared lap's distance is scaled by reference.length / lap.length
    /// first, so line differences don't accumulate as fake time loss.
    /// Positive = `lap` is behind the reference.
    public static func timeDelta(reference: LapTrace, lap: LapTrace) -> [Double]
}

public struct SplitResult: Sendable { public var index: Int; public var startDistance: Double; public var endDistance: Double; public var time: Double }
public enum Splits {
    /// Split times for a lap given split boundaries in metres (ascending, exclusive of 0 and lap end).
    public static func times(trace: LapTrace, boundaries: [Double]) -> [SplitResult]
    /// n equal-distance boundaries.
    public static func equalBoundaries(length: Double, count: Int) -> [Double]
    /// Sum of the best time per split across laps ("theoretical best").
    public static func theoreticalBest(_ perLap: [[SplitResult]]) -> Double?
}

public struct HistogramBin: Sendable { public var lower: Double; public var upper: Double; public var seconds: Double; public var fraction: Double }
public enum Histogram {
    /// Time-weighted histogram of a channel within [start, end] (session seconds).
    public static func bins(channel: Channel, start: Double, end: Double, binCount: Int) -> [HistogramBin]
}

public struct ChannelStats: Sendable { public var min: Double; public var max: Double; public var mean: Double }
public enum Stats {
    public static func stats(channel: Channel, start: Double, end: Double) -> ChannelStats?
}

public enum Geo {
    /// Local east/north metres relative to an origin (equirectangular; fine at track scale).
    public static func project(latitude: [Double], longitude: [Double]) -> [(x: Double, y: Double)]
    public static func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double
}
```

### Device (`Sources/LapCore/Device/`) — planned

Wi-Fi discovery and download from the Solo 2. Blocked on packet captures; see
`docs/wifi-protocol.md`.

## Conventions

- Time: seconds as `Double`. Distance: metres. Speed: m/s in the model, converted for display only.
- No force unwraps on file-derived data; malformed input throws `XRKError`.
- Tests use `Bundle.module` to load `Fixtures/`.
