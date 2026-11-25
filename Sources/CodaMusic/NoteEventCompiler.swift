import Foundation

public enum NoteEventKind: Int, Sendable { case noteOff = 0, noteOn = 1 }

/// Value payload only. Compilation/Array ownership must stay OFF the render thread.
/// noteOff means release the envelope, never hard-cut a DSP voice.
public struct NoteEvent: Equatable, Sendable {
    public let sampleOffset: Int64
    public let kind: NoteEventKind
    public let pitch: UInt8
    public let voiceIndex: Int
    public let regionIndex: Int
}

public struct CompiledLoop: Equatable, Sendable {
    public let originSample: Int64
    public let sampleCount: Int64
    public let events: [NoteEvent]
}

public enum NoteEventCompiler {
    /// One closed cycle: process terminal offs at sampleCount BEFORE restarting at
    /// zero. No sentinel/all-notes-off/hard cut; silent loops still have sampleCount.
    /// A region crossing a loop boundary is clipped and retriggered at loop start.
    public static func compile(_ progression: Progression, tempo: Double,
                               sampleRate: Double, loop: LoopSpan,
                               cycleIndex: Int64 = 0) throws -> CompiledLoop {
        guard tempo.isFinite, tempo > 0 else { throw MusicError.invalidTempo }
        guard sampleRate.isFinite, sampleRate > 0 else { throw MusicError.invalidSampleRate }
        guard loop.end <= progression.totalSteps else { throw MusicError.invalidSpan }
        guard cycleIndex >= 0 else { throw MusicError.invalidSpan }
        let (cycleStartStep, multipliedOverflow) = cycleIndex.multipliedReportingOverflow(by: Int64(loop.length))
        let (cycleEndStep, addedOverflow) = cycleStartStep.addingReportingOverflow(Int64(loop.length))
        // Above 2^53 a Double cannot represent every integer grid step.
        guard !multipliedOverflow, !addedOverflow, cycleEndStep <= 9_007_199_254_740_992 else {
            throw MusicError.timingOverflow
        }
        let samplesPerStep = sampleRate * 60 / tempo / Double(MusicDefaults.stepsPerBeat)
        func sample(_ step: Int64) throws -> Int64 {
            let value = (Double(step) * samplesPerStep).rounded(.toNearestOrAwayFromZero)
            guard value.isFinite, value >= 0, value < Double(Int64.max) else { throw MusicError.timingOverflow }
            return Int64(value)
        }
        let origin = try sample(cycleStartStep)
        func offset(_ step: Int) throws -> Int64 {
            try sample(cycleStartStep + Int64(step)) - origin
        }
        let count = try offset(loop.length)
        guard count > 0 else { throw MusicError.timingOverflow }
        var events: [NoteEvent] = []
        for (index, region) in progression.regions.enumerated() {
            let start = max(loop.start, region.start)
            let end = min(loop.end, region.end)
            guard start < end else { continue }
            let on = try offset(start - loop.start)
            let off = try offset(end - loop.start)
            guard off > on else { throw MusicError.timingOverflow }
            for (voice, pitch) in region.pitches.enumerated() {
                events.append(NoteEvent(sampleOffset: on, kind: .noteOn, pitch: UInt8(pitch), voiceIndex: voice, regionIndex: index))
                events.append(NoteEvent(sampleOffset: off, kind: .noteOff, pitch: UInt8(pitch), voiceIndex: voice, regionIndex: index))
            }
        }
        events.sort {
            if $0.sampleOffset != $1.sampleOffset { return $0.sampleOffset < $1.sampleOffset }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.voiceIndex != $1.voiceIndex { return $0.voiceIndex < $1.voiceIndex }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.regionIndex < $1.regionIndex
        }
        return CompiledLoop(originSample: origin, sampleCount: count, events: events)
    }
}
