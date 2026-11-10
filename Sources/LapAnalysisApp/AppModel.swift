import Foundation
import Observation
import SwiftUI
import LapCore

/// Holds loaded sessions, selection state and the cached analysis output.
/// All mutation happens on the main actor; heavy work (parsing, resampling,
/// delta/downsample/splits) runs in detached tasks and hands back Sendable values.
@MainActor
@Observable
final class AppModel {
    // MARK: Library
    var sessions: [LoadedSession] = []
    var loadingFiles: [LoadingFile] = []
    var issues: [LoadIssue] = []
    var selectedSessionIDs: Set<UUID> = []
    var showImporter: Bool = false

    // MARK: Selection / settings
    var checkedLaps: Set<LapKey> = []
    var referenceOverride: LapKey?
    var lapColorIndex: [LapKey: Int] = [:]
    var selectedChannel: String = ChannelName.gpsSpeed
    var speedUnit: SpeedUnit = .mph
    var splitCount: Int = 5
    var cursorDistance: Double?

    // MARK: Derived output
    var analysis: AnalysisResult = AnalysisResult.empty
    var computingTraces: Int = 0
    var defaultReferenceKey: LapKey?

    // MARK: Non-observed internals
    @ObservationIgnored private var traces: [LapKey: LapTrace] = [:]
    @ObservationIgnored private var pendingTraces: Set<LapKey> = []
    @ObservationIgnored private var failedTraces: Set<LapKey> = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    // MARK: - Opening files

    func open(urls: [URL]) {
        for url in urls { load(url) }
    }

    func openDropped(url: URL) {
        let ext: String = url.pathExtension.lowercased()
        if ext == "xrk" || ext == "xrz" {
            load(url)
        } else {
            issues.append(LoadIssue(fileName: url.lastPathComponent, message: "Unsupported file type (expected .xrk or .xrz)."))
        }
    }

    func report(error: Error, fileName: String) {
        issues.append(LoadIssue(fileName: fileName, message: AppModel.describe(error)))
    }

    private func load(_ url: URL) {
        let token: UUID = UUID()
        let name: String = url.lastPathComponent
        loadingFiles.append(LoadingFile(id: token, fileName: name))
        Task {
            let result: Result<Session, Error> = await Task.detached(priority: .userInitiated) { () -> Result<Session, Error> in
                let scoped: Bool = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let session: Session = try XRKParser.parse(contentsOf: url)
                    return .success(session)
                } catch {
                    return .failure(error)
                }
            }.value
            self.finishLoad(token: token, fileName: name, result: result)
        }
    }

    private func finishLoad(token: UUID, fileName: String, result: Result<Session, Error>) {
        loadingFiles.removeAll { (f: LoadingFile) -> Bool in f.id == token }
        switch result {
        case .success(let session):
            let loaded: LoadedSession = LoadedSession(id: UUID(), fileName: fileName, session: session)
            sessions.append(loaded)
            recomputeDefaultReference()
            if let best = session.bestLap {
                let key: LapKey = LapKey(sessionID: loaded.id, lapNumber: best.number)
                checkedLaps.insert(key)
                assignColor(key)
            }
            selectionChanged()
        case .failure(let error):
            report(error: error, fileName: fileName)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }

    func dismissIssue(_ id: UUID) {
        issues.removeAll { (i: LoadIssue) -> Bool in i.id == id }
    }

    func close(sessionIDs: Set<UUID>) {
        sessions.removeAll { (s: LoadedSession) -> Bool in sessionIDs.contains(s.id) }
        checkedLaps = checkedLaps.filter { (k: LapKey) -> Bool in !sessionIDs.contains(k.sessionID) }
        traces = traces.filter { (pair: (key: LapKey, value: LapTrace)) -> Bool in !sessionIDs.contains(pair.key.sessionID) }
        lapColorIndex = lapColorIndex.filter { (pair: (key: LapKey, value: Int)) -> Bool in !sessionIDs.contains(pair.key.sessionID) }
        selectedSessionIDs.subtract(sessionIDs)
        if let o = referenceOverride, sessionIDs.contains(o.sessionID) { referenceOverride = nil }
        recomputeDefaultReference()
        selectionChanged()
    }

    // MARK: - Lookup

    var visibleSessions: [LoadedSession] {
        if selectedSessionIDs.isEmpty { return sessions }
        return sessions.filter { (s: LoadedSession) -> Bool in selectedSessionIDs.contains(s.id) }
    }

    private func baseName(_ s: LoadedSession) -> String {
        let driver: String = s.session.metadata.driver
        return driver.isEmpty ? s.fileName : driver
    }

    /// Driver name (or file name), disambiguated with #n when two sessions share it.
    func sessionLabel(_ id: UUID) -> String {
        guard let idx = sessions.firstIndex(where: { (s: LoadedSession) -> Bool in s.id == id }) else { return "?" }
        let base: String = baseName(sessions[idx])
        var same: Int = 0
        for s in sessions where baseName(s) == base { same += 1 }
        return same > 1 ? base + " #" + String(idx + 1) : base
    }

    func lapLabel(_ key: LapKey) -> String {
        return sessionLabel(key.sessionID) + " L" + String(key.lapNumber)
    }

    func lap(for key: LapKey) -> Lap? {
        guard let s = sessions.first(where: { (x: LoadedSession) -> Bool in x.id == key.sessionID }) else { return nil }
        return s.session.laps.first(where: { (l: Lap) -> Bool in l.number == key.lapNumber })
    }

    var referenceKey: LapKey? {
        if let o = referenceOverride, lap(for: o) != nil { return o }
        return defaultReferenceKey
    }

    private func recomputeDefaultReference() {
        var bestKey: LapKey?
        var bestTime: Double = Double.infinity
        for s in sessions {
            if let l = s.session.bestLap, l.duration < bestTime {
                bestTime = l.duration
                bestKey = LapKey(sessionID: s.id, lapNumber: l.number)
            }
        }
        defaultReferenceKey = bestKey
    }

    var availableChannels: [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for s in sessions {
            for c in s.session.channels where !seen.contains(c.name) {
                seen.insert(c.name)
                names.append(c.name)
            }
        }
        if let i = names.firstIndex(of: ChannelName.gpsSpeed), i != 0 {
            names.remove(at: i)
            names.insert(ChannelName.gpsSpeed, at: 0)
        }
        return names
    }

    func channelDisplay(for name: String) -> ChannelDisplay {
        var units: String = ""
        for s in sessions {
            if let c = s.session.channel(name) {
                units = c.units
                break
            }
        }
        if name == ChannelName.gpsSpeed { units = "m/s" }
        let lower: String = units.lowercased()
        var toMetersPerSecond: Double?
        if lower == "m/s" {
            toMetersPerSecond = 1.0
        } else if lower == "km/h" || lower == "kph" {
            toMetersPerSecond = 1.0 / 3.6
        } else if lower == "mph" {
            toMetersPerSecond = 1.0 / 2.2369362921
        }
        if let f = toMetersPerSecond {
            return ChannelDisplay(scale: f * speedUnit.factorFromMetersPerSecond, unit: speedUnit.label)
        }
        return ChannelDisplay(scale: 1.0, unit: units)
    }

    var channelAxisLabel: String {
        let d: ChannelDisplay = channelDisplay(for: selectedChannel)
        return d.unit.isEmpty ? selectedChannel : selectedChannel + " (" + d.unit + ")"
    }

    /// Checked laps in session/lap order.
    var orderedCheckedKeys: [LapKey] {
        var out: [LapKey] = []
        for s in sessions {
            for lap in s.session.laps {
                let key: LapKey = LapKey(sessionID: s.id, lapNumber: lap.number)
                if checkedLaps.contains(key) { out.append(key) }
            }
        }
        return out
    }

    func isDimmed(sessionID: UUID, lap: Lap, in session: Session) -> Bool {
        guard session.laps.count >= 3 else { return false }
        return lap.number == session.laps.first?.number || lap.number == session.laps.last?.number
    }

    // MARK: - Selection actions

    private func assignColor(_ key: LapKey) {
        if lapColorIndex[key] != nil { return }
        let used: Set<Int> = Set(lapColorIndex.values)
        var i: Int = 0
        while used.contains(i) { i += 1 }
        lapColorIndex[key] = i
    }

    func setChecked(_ key: LapKey, _ on: Bool) {
        if on {
            checkedLaps.insert(key)
            assignColor(key)
        } else {
            checkedLaps.remove(key)
            lapColorIndex[key] = nil
        }
        selectionChanged()
    }

    func clearChecked() {
        checkedLaps.removeAll()
        lapColorIndex.removeAll()
        selectionChanged()
    }

    func checkBestLaps() {
        for s in visibleSessions {
            if let best = s.session.bestLap {
                let key: LapKey = LapKey(sessionID: s.id, lapNumber: best.number)
                checkedLaps.insert(key)
                assignColor(key)
            }
        }
        selectionChanged()
    }

    func setReference(_ key: LapKey) {
        referenceOverride = key
        selectionChanged()
    }

    func resetReference() {
        referenceOverride = nil
        selectionChanged()
    }

    func setChannel(_ name: String) {
        selectedChannel = name
        scheduleRebuild()
    }

    func setSpeedUnit(_ unit: SpeedUnit) {
        speedUnit = unit
        scheduleRebuild()
    }

    func setSplitCount(_ n: Int) {
        splitCount = min(max(n, 3), 8)
        scheduleRebuild()
    }

    // MARK: - Traces (lazy, off-main, cached)

    private func selectionChanged() {
        var needed: [LapKey] = orderedCheckedKeys
        if let r = referenceKey { needed.append(r) }
        for key in needed { ensureTrace(key) }
        scheduleRebuild()
    }

    private func ensureTrace(_ key: LapKey) {
        if traces[key] != nil || pendingTraces.contains(key) || failedTraces.contains(key) { return }
        guard let loaded = sessions.first(where: { (s: LoadedSession) -> Bool in s.id == key.sessionID }),
              let lapValue = self.lap(for: key) else { return }
        pendingTraces.insert(key)
        computingTraces += 1
        let session: Session = loaded.session
        let label: String = lapLabel(key)
        Task {
            let trace: LapTrace? = await Task.detached(priority: .userInitiated) { () -> LapTrace? in
                return LapResampler.trace(session: session, lap: lapValue, step: 1.0, label: label)
            }.value
            self.traceFinished(key: key, trace: trace)
        }
    }

    private func traceFinished(key: LapKey, trace: LapTrace?) {
        pendingTraces.remove(key)
        computingTraces = max(0, computingTraces - 1)
        // The session may have been closed while we were computing.
        guard sessions.contains(where: { (s: LoadedSession) -> Bool in s.id == key.sessionID }) else { return }
        if let t = trace {
            traces[key] = t
        } else {
            failedTraces.insert(key)
        }
        scheduleRebuild()
    }

    /// True when a checked lap could not be resampled (no GPS speed).
    func hasFailedTrace(_ key: LapKey) -> Bool {
        return failedTraces.contains(key)
    }

    // MARK: - Analysis rebuild

    private func makeEntry(_ key: LapKey, _ trace: LapTrace) -> LapEntry {
        return LapEntry(key: key, label: lapLabel(key), colorIndex: lapColorIndex[key] ?? 0, trace: trace)
    }

    private func makeInput() -> AnalysisInput {
        let refKey: LapKey? = referenceKey
        var refEntry: LapEntry?
        if let rk = refKey, let t = traces[rk] { refEntry = makeEntry(rk, t) }
        var entries: [LapEntry] = []
        for key in orderedCheckedKeys {
            if let t = traces[key] { entries.append(makeEntry(key, t)) }
        }
        let display: ChannelDisplay = channelDisplay(for: selectedChannel)
        return AnalysisInput(referenceKey: refKey, reference: refEntry, laps: entries,
                             channel: selectedChannel, channelScale: display.scale, splitCount: splitCount)
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        let input: AnalysisInput = makeInput()
        rebuildTask = Task {
            let result: AnalysisResult = await Task.detached(priority: .userInitiated) { () -> AnalysisResult in
                return AnalysisBuilder.build(input)
            }.value
            if Task.isCancelled { return }
            self.analysis = result
        }
    }
}
