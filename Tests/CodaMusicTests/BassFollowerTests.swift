import Foundation
import XCTest
@testable import CodaMusic

final class BassFollowerTests: PatternCompilerTestCase {

    // MARK: - Stage 1 Fixes

    func testChordRollEditorVoicingDeduplicatesDuplicatePitches() throws {
        let r = try region(pitches: [60, 63, 67])
        let updated = try ChordRollEditor.voicing(r, pitches: [64, 60, 60, 67, 64])
        XCTAssertEqual(updated.pitches, [60, 64, 67])
        XCTAssertEqual(updated.notes.count, 3)
    }

    func testPatternCompilerCarryInSkipsChuckAcrossBarBoundary() throws {
        let v = try vocabulary()
        // 2-bar chord covered by a pattern whose last slot (slot 7) is a chuck
        let chordRegion = try region("c1", start: 0, length: 32, pitches: [60, 63, 67, 70])
        let p = try Progression(totalSteps: 32, regions: [chordRegion], vocabulary: v)
        let pat = try pattern([
            0: arrow(8, .down),
            7: .chuck(ChuckSize(0.7))
        ], start: 0, bars: 2, id: "pat")
        let arr = try PatternArrangement(barCount: 2, regions: [pat])

        // Compile bar 1 (steps 16..<32) with carryIn: true
        let bar1 = try LoopSpan(start: 16, bars: 1)
        let compiled = try PatternEventCompiler.compile(
            p, arrangement: arr, tempo: 120, sampleRate: 48_000,
            loop: bar1, cycleIndex: 0, forcePerformance: true, carryIn: true, carryOut: false
        )
        guard case .pattern(let loop) = compiled else {
            return XCTFail("Expected .pattern compilation")
        }
        // No chuck should re-trigger at sample 0 of bar 1, and nothing from before the chuck carries in.
        let sample0Chucks = loop.events.filter { $0.sampleOffset == 0 && $0.attackMode == .chuck }
        XCTAssertTrue(sample0Chucks.isEmpty)
        let carriedIn = loop.events.filter { $0.continuesFromPrevious }
        XCTAssertTrue(carriedIn.isEmpty)
    }

    // MARK: - MusicLayer & Track Models

    func testMusicLayerNativeIndices() {
        XCTAssertEqual(MusicLayer.chords.nativeIndex, 0)
        XCTAssertEqual(MusicLayer.bass.nativeIndex, 1)
        XCTAssertEqual(MusicLayer.melody.nativeIndex, 2)
    }

    func testBassTrackEditHelpersAndOverlapValidation() throws {
        let n1 = try BassNote(id: "b1", startTick: 0, durationTicks: 480, pitch: 48, velocity: 100)
        let n2 = try BassNote(id: "b2", startTick: 480, durationTicks: 480, pitch: 48, velocity: 95)
        var track = try BassTrack(notes: [n2, n1])
        XCTAssertEqual(track.notes.map(\.id), ["b1", "b2"])

        // Overlap on same pitch must throw
        let overlapping = try BassNote(id: "b3", startTick: 240, durationTicks: 480, pitch: 48)
        XCTAssertThrowsError(try track.adding(overlapping)) { XCTAssertEqual($0 as? MusicError, .overlap) }

        // Move, resize, toggleSlide, transpose, nudge, slice
        track = try track.moving(id: "b2", toStartTick: 960, pitch: 50)
        XCTAssertEqual(track.notes.first(where: { $0.id == "b2" })?.pitch, 50)
        XCTAssertEqual(track.notes.first(where: { $0.id == "b2" })?.userEdited, true)

        track = try track.resizing(id: "b1", durationTicks: 960)
        XCTAssertEqual(track.notes.first(where: { $0.id == "b1" })?.durationTicks, 960)

        track = try track.togglingSlide(id: "b1")
        XCTAssertEqual(track.notes.first(where: { $0.id == "b1" })?.slide, true)

        track = try track.transposing(ids: ["b1"], semitones: 2)
        XCTAssertEqual(track.notes.first(where: { $0.id == "b1" })?.pitch, 50)

        track = try track.nudging(ids: ["b2"], deltaTicks: 120)
        XCTAssertEqual(track.notes.first(where: { $0.id == "b2" })?.startTick, 1080)

        track = try track.slicing(id: "b1", atTick: 480, rightID: "b1-r")
        XCTAssertEqual(track.notes.count, 3)

        let copied = track.copying(ids: ["b1", "b1-r"])
        XCTAssertEqual(copied.count, 2)
        var counter = 0
        track = try track.pasting(copied, atTick: 2400) {
            counter += 1
            return "pasted-\(counter)"
        }
        XCTAssertEqual(track.notes.count, 5)

        track = try track.deleting(ids: ["pasted-1", "pasted-2"])
        XCTAssertEqual(track.notes.count, 3)

        XCTAssertTrue(track.clearing().notes.isEmpty)
    }

    func testMelodyTrackEditHelpersAndNudge() throws {
        let m1 = try MelodyNote(id: "m1", startTick: 480, durationTicks: 480, pitch: 72, velocity: 110, nudgeTicks: -15)
        XCTAssertEqual(m1.effectiveStartTick, 465)
        XCTAssertEqual(m1.effectiveEndTick, 945)

        var track = try MelodyTrack(notes: [m1])
        track = try track.nudging(id: "m1", nudgeTicks: 20)
        XCTAssertEqual(track.notes[0].effectiveStartTick, 500)

        track = try track.nudging(ids: ["m1"], deltaTicks: -10)
        XCTAssertEqual(track.notes[0].nudgeTicks, 10)

        track = try track.slicing(id: "m1", atTick: 720, rightID: "m2")
        XCTAssertEqual(track.notes.count, 2)
        track = try track.togglingSlide(id: "m2")
        XCTAssertTrue(track.notes.first(where: { $0.id == "m2" })?.slide ?? false)
        track = try track.transposing(semitones: -2)
        XCTAssertEqual(track.notes.map(\.pitch), [70, 70])
        XCTAssertTrue(track.clearing().notes.isEmpty)
    }

    // MARK: - BassFollower (SPEC §9)

    func testSeedFromProgressionRespectsOctaveWindowAndSlashBass() throws {
        let v = try vocabulary()
        let cMin7 = try chord(0, "minor7")
        let fSlashA = try chord(5, "major", slash: 9) // F/A
        let gDom7 = try chord(7, "dominant7")
        let p = try Progression(
            totalSteps: 48,
            regions: [
                region("r1", start: 0, length: 16, chord: cMin7),
                region("r2", start: 16, length: 16, chord: fSlashA),
                region("r3", start: 32, length: 16, chord: gDom7)
            ],
            vocabulary: v
        )

        let seeded = BassFollower.seedFromProgression(p, vocabulary: v)
        XCTAssertEqual(seeded.count, 3)
        for note in seeded {
            XCTAssertTrue(BassFollower.defaultOctaveWindow.contains(note.pitch), "Pitch \(note.pitch) outside window")
        }
        XCTAssertEqual(seeded[0].pitch % 12, 0) // C
        XCTAssertEqual(seeded[1].pitch % 12, 9) // A (slash bass!)
        XCTAssertEqual(seeded[2].pitch % 12, 7) // G
        XCTAssertEqual(seeded[0].startTick, 0)
        XCTAssertEqual(seeded[1].startTick, 16 * MusicDefaults.ticksPerStep)
        XCTAssertEqual(seeded[2].startTick, 32 * MusicDefaults.ticksPerStep)
    }

    func testReconcileFollowsChordToneFunctionAcrossQualityChange() throws {
        let v = try vocabulary()
        let prevRegion = try region("r1", start: 0, length: 16, chord: chord(0, "minor7"))
        let newRegion = try region("r1", start: 0, length: 16, chord: chord(0, "major7"))

        // Bass note on minor 3rd (Eb = 39) and minor 7th (Bb = 46)
        let thirdNote = try BassNote(
            id: "b3", startTick: 0, durationTicks: 480, pitch: 39, velocity: 99, slide: true,
            provenance: .chordTone(intervalFromRoot: 3), userEdited: true
        )
        let seventhNote = try BassNote(
            id: "b7", startTick: 480, durationTicks: 480, pitch: 46, velocity: 92, slide: false,
            provenance: .chordTone(intervalFromRoot: 10), userEdited: true
        )

        let reconciled = BassFollower.reconcile(
            bassNotes: [thirdNote, seventhNote],
            previousRegions: [prevRegion],
            newRegions: [newRegion],
            vocabulary: v
        )

        XCTAssertEqual(reconciled.count, 2)
        // m3 (Eb=39) -> M3 (E=40)
        XCTAssertEqual(reconciled[0].pitch, 40)
        XCTAssertEqual(reconciled[0].provenance, .chordTone(intervalFromRoot: 4))
        XCTAssertEqual(reconciled[0].startTick, 0)
        XCTAssertEqual(reconciled[0].durationTicks, 480)
        XCTAssertEqual(reconciled[0].velocity, 99)
        XCTAssertEqual(reconciled[0].slide, true)

        // m7 (Bb=46) -> Maj7 (B=47)
        XCTAssertEqual(reconciled[1].pitch, 47)
        XCTAssertEqual(reconciled[1].provenance, .chordTone(intervalFromRoot: 11))
    }

    func testReconcilePreservesFixedOffsetForNonChordTone() throws {
        let v = try vocabulary()
        let prevRegion = try region("r1", start: 0, length: 16, chord: chord(0, "major"))
        let newRegion = try region("r1", start: 0, length: 16, chord: chord(5, "minor7"))

        // C# (1 semitone above C) -> must become F# (1 semitone above F = pc 6)
        let passing = try BassNote(
            id: "pass", startTick: 240, durationTicks: 240, pitch: 37, velocity: 88, slide: false,
            provenance: .fixedOffset(semitonesFromRoot: 1), userEdited: true
        )

        let reconciled = BassFollower.reconcile(
            bassNotes: [passing],
            previousRegions: [prevRegion],
            newRegions: [newRegion],
            vocabulary: v
        )

        XCTAssertEqual(reconciled[0].pitch % 12, 6) // F#
        XCTAssertEqual(reconciled[0].provenance, .fixedOffset(semitonesFromRoot: 1))
        XCTAssertTrue(BassFollower.defaultOctaveWindow.contains(reconciled[0].pitch))
    }

    func testReconcileAvoidsOctaveJumpOnRootChangeCtoB() throws {
        let v = try vocabulary()
        let prevRegion = try region("r1", start: 0, length: 16, chord: chord(0, "major"))
        let newRegion = try region("r1", start: 0, length: 16, chord: chord(11, "minor7"))

        // C3 = 48 -> B2 = 47 (1 semitone down, not jumping an octave)
        let rootNote = try BassNote(
            id: "root", startTick: 0, durationTicks: 960, pitch: 48,
            provenance: .chordTone(intervalFromRoot: 0), userEdited: false
        )

        let reconciled = BassFollower.reconcile(
            bassNotes: [rootNote],
            previousRegions: [prevRegion],
            newRegions: [newRegion],
            vocabulary: v
        )
        XCTAssertEqual(reconciled[0].pitch, 47)
    }

    func testEvaluateProvenanceDetectsChordToneVsFixedOffset() throws {
        let v = try vocabulary()
        let r = try region("r1", start: 0, length: 16, chord: chord(0, "minor7"))
        XCTAssertEqual(BassFollower.evaluateProvenance(pitch: 43, atTick: 0, in: [r], vocabulary: v), .chordTone(intervalFromRoot: 7))
        XCTAssertEqual(BassFollower.evaluateProvenance(pitch: 39, atTick: 120, in: [r], vocabulary: v), .chordTone(intervalFromRoot: 3))
        XCTAssertEqual(BassFollower.evaluateProvenance(pitch: 37, atTick: 120, in: [r], vocabulary: v), .fixedOffset(semitonesFromRoot: 1))
    }

    // MARK: - MultiLayerEventCompiler

    func testMultiLayerEventCompilerMergesLayersRespectsMutesAndContinuationKeys() throws {
        let v = try vocabulary()
        let p = try Progression(totalSteps: 16, regions: [region("r1", start: 0, length: 16, pitches: [60, 63, 67])], vocabulary: v)
        let arr = try PatternArrangement(barCount: 1, regions: [])
        let bass = try BassTrack(notes: [BassNote(id: "b1", startTick: 0, durationTicks: 960, pitch: 36, velocity: 110, slide: true)])
        let melody = try MelodyTrack(notes: [MelodyNote(id: "m1", startTick: 480, durationTicks: 480, pitch: 79, velocity: 105, nudgeTicks: 10)])
        let span = try LoopSpan(start: 0, bars: 1)

        let merged = try MultiLayerEventCompiler.compileWindow(
            progression: p, arrangement: arr, bass: bass, melody: melody,
            tempo: 120, sampleRate: 48_000, loop: span
        )

        let chordOns = merged.events.filter { $0.layer == .chords && $0.kind == .noteOn }
        let bassOns = merged.events.filter { $0.layer == .bass && $0.kind == .noteOn }
        let melodyOns = merged.events.filter { $0.layer == .melody && $0.kind == .noteOn }

        XCTAssertEqual(chordOns.count, 3)
        XCTAssertEqual(bassOns.count, 1)
        XCTAssertEqual(melodyOns.count, 1)
        XCTAssertTrue(bassOns[0].continuationKey?.hasPrefix("bass:") ?? false)
        XCTAssertTrue(melodyOns[0].continuationKey?.hasPrefix("melody:") ?? false)
        XCTAssertTrue(bassOns[0].slide)

        // Verify strictly non-decreasing sample offsets
        for (a, b) in zip(merged.events, merged.events.dropFirst()) {
            XCTAssertLessThanOrEqual(a.sampleOffset, b.sampleOffset)
        }

        // Mute bass & chords -> only melody events remain
        let melodyOnly = try MultiLayerEventCompiler.compileWindow(
            progression: p, arrangement: arr, bass: bass, melody: melody,
            mutedLayers: [.chords, .bass], tempo: 120, sampleRate: 48_000, loop: span
        )
        XCTAssertTrue(melodyOnly.events.allSatisfy { $0.layer == .melody })
        XCTAssertEqual(melodyOnly.events.count, 2)
    }
}
