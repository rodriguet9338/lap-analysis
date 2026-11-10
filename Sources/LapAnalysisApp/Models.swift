import Foundation
import LapCore

/// Identifies one lap of one loaded session.
struct LapKey: Hashable, Sendable {
    let sessionID: UUID
    let lapNumber: Int

    var stringID: String { sessionID.uuidString + "-" + String(lapNumber) }
}

struct LoadedSession: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let session: Session
}

struct LoadingFile: Identifiable {
    let id: UUID
    let fileName: String
}

struct LoadIssue: Identifiable {
    let id: UUID = UUID()
    let fileName: String
    let message: String
}

/// Display scaling for the plotted channel.
struct ChannelDisplay {
    var scale: Double
    var unit: String
}

/// A checked lap whose trace is ready, ready to hand to the off-main builder.
struct LapEntry: Sendable {
    let key: LapKey
    let label: String
    let colorIndex: Int
    let trace: LapTrace
}

struct AnalysisInput: Sendable {
    var referenceKey: LapKey?
    var reference: LapEntry?
    var laps: [LapEntry]
    var channel: String
    var channelScale: Double
    var splitCount: Int
}
