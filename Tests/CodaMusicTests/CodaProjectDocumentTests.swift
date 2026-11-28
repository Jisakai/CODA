import Foundation
import XCTest
@testable import CodaMusic

final class CodaProjectDocumentTests: MusicTestCase {
    func testFullDocumentJSONRoundTripWithAllLayersPatternAndABSnapshot() throws {
        let v = try vocabulary()
        let created = Date(timeIntervalSince1970: 1_764_000_000)
        let modified = Date(timeIntervalSince1970: 1_764_003_600)

        let c1 = try region("c1", start: 0, length: 16, chord: chord(0, "minor9"))
        let c2 = try ChordRegion(
            id: "c2",
            chord: chord(5, "minor7", slash: 0),
            start: 16,
            length: 16,
            pitches: [53, 56, 60, 63],
            detectionUncertain: true
        )

        let bassNotes = [
            try BassNote(id: "b1", startTick: 0, durationTicks: 960, pitch: 36, velocity: 108, slide: true, provenance: .chordTone(intervalFromRoot: 0), userEdited: false),
            try BassNote(id: "b2", startTick: 960, durationTicks: 480, pitch: 37, velocity: 90, slide: false, provenance: .fixedOffset(semitonesFromRoot: 1), userEdited: true)
        ]

        let melodyNotes = [
            try MelodyNote(id: "m1", startTick: 240, durationTicks: 480, pitch: 75, velocity: 102, slide: true, nudgeTicks: -12)
        ]

        let patRegion = try PatternPreset.popRock.instantiate(
            id: "pat-1",
            range: PatternBarRange(start: 0, length: 2),
            occupiedStrokeIDs: ["s1", "s2", "s3", "s4", "s5", "s6"],
            settings: PatternSettings(swing: 0.35, humanize: .loose, spreadMilliseconds: 28, looseSeed: 42)
        )
        let arrangement = try PatternArrangement(barCount: 16, regions: [patRegion])

        var synth = MixerAndSynthState()
        synth.bass.muted = true
        synth.chords.wobble = 0.62
        synth.sharedFX.reverbMix = 0.41

        let viewport = ViewportState(
            activeLayer: .melody,
            scrollStep: 16,
            horizontalZoom: 1.5,
            verticalScrollPitch: 64,
            verticalZoom: 1.2,
            gridSnapEnabled: false,
            showNoteLabels: true
        )

        var doc = CodaProjectDocument(
            id: "proj-001",
            name: "Late Night Sketch",
            createdAt: created,
            modifiedAt: modified,
            tempo: 118.5,
            key: MusicalKey(tonic: 2, mode: .naturalMinor),
            loopSpan: try LoopSpan(start: 0, bars: 4),
            looping: true,
            arrangementTotalSteps: 256, // 16 bars — unbounded arrangement support
            chordRegions: [c1, c2],
            bassNotes: bassNotes,
            melodyNotes: melodyNotes,
            patternArrangement: arrangement,
            synthState: synth,
            viewport: viewport,
            abSnapshot: nil
        )
        doc.abSnapshot = doc.captureABSnapshot(label: "A", at: created)

        let data = try doc.encodeJSON(prettyPrinted: true)
        let decoded = try CodaProjectDocument.decodeJSON(data)

        XCTAssertEqual(decoded, doc)
        XCTAssertEqual(decoded.schemaVersion, CodaProjectDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.synthState.mutedLayers, [.bass])
        XCTAssertEqual(decoded.chordRegions[1].detectionUncertain, true)
        XCTAssertEqual(decoded.bassNotes[1].provenance, .fixedOffset(semitonesFromRoot: 1))
        XCTAssertEqual(decoded.melodyNotes[0].nudgeTicks, -12)
        XCTAssertNotNil(decoded.abSnapshot)

        // Verify domain reconstruction
        let progression = try decoded.makeProgression(vocabulary: v)
        XCTAssertEqual(progression.totalSteps, 256)
        XCTAssertEqual(progression.regions.count, 2)
        XCTAssertEqual(try decoded.makeBassTrack().notes.count, 2)
        XCTAssertEqual(try decoded.makeMelodyTrack().notes.count, 1)
    }

    func testRejectsUnsupportedSchemaVersionAndCorruptFields() throws {
        var futureDoc = CodaProjectDocument(schemaVersion: 99, id: "proj-future")
        let futureData = try futureDoc.encodeJSON(prettyPrinted: false)
        XCTAssertThrowsError(try CodaProjectDocument.decodeJSON(futureData)) { error in
            XCTAssertEqual(error as? ProjectDocumentError, .unsupportedSchemaVersion(99))
        }

        futureDoc.schemaVersion = 1
        futureDoc.tempo = -10
        let badTempoData = try futureDoc.encodeJSON(prettyPrinted: false)
        XCTAssertThrowsError(try CodaProjectDocument.decodeJSON(badTempoData))
    }
}
