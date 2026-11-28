import Foundation
import XCTest
@testable import CodaMusic

final class MIDIExporterTests: PatternCompilerTestCase {

    // MARK: - VLQ Encoding

    func testVLQEncodingBoundaryValues() {
        XCTAssertEqual(MIDIExporter.encodeVLQ(0), [0x00])
        XCTAssertEqual(MIDIExporter.encodeVLQ(127), [0x7F])
        XCTAssertEqual(MIDIExporter.encodeVLQ(128), [0x81, 0x00])
        XCTAssertEqual(MIDIExporter.encodeVLQ(480), [0x83, 0x60])
        XCTAssertEqual(MIDIExporter.encodeVLQ(16_383), [0xFF, 0x7F])
        XCTAssertEqual(MIDIExporter.encodeVLQ(16_384), [0x81, 0x80, 0x00])
    }

    // MARK: - SMF Format 1 Export & Structural Validation

    func testExportProducesValidSMFFormat1WithPatternExpandedChordsBassAndMelody() throws {
        let v = try vocabulary()
        let p = try Progression(
            totalSteps: 32,
            regions: [
                region("r1", start: 0, length: 16, chord: chord(0, "minor7"), pitches: [60, 63, 67, 70]),
                region("r2", start: 16, length: 16, chord: chord(5, "minor7"), pitches: [53, 56, 60, 63])
            ],
            vocabulary: v
        )
        let pat = try PatternPreset.popRock.instantiate(
            id: "poprock",
            range: PatternBarRange(start: 0, length: 2),
            occupiedStrokeIDs: ["s1", "s2", "s3", "s4", "s5", "s6"],
            settings: PatternSettings(swing: 0, humanize: .tight, spreadMilliseconds: 15)
        )
        let arrangement = try PatternArrangement(barCount: 2, regions: [pat])
        let bass = try BassTrack(notes: [
            BassNote(id: "b1", startTick: 0, durationTicks: 1920, pitch: 36, velocity: 100),
            BassNote(id: "b2", startTick: 1920, durationTicks: 1920, pitch: 41, velocity: 104)
        ])
        let melody = try MelodyTrack(notes: [
            MelodyNote(id: "m1", startTick: 480, durationTicks: 480, pitch: 75, velocity: 112)
        ])

        let data = try MIDIExporter.export(
            progression: p,
            patternArrangement: arrangement,
            bass: bass,
            melody: melody,
            tempo: 120.0,
            key: MusicalKey(tonic: 0, mode: .naturalMinor),
            projectName: "Test Sketch"
        )

        let parsed = try parseSMF(data)
        XCTAssertEqual(parsed.format, 1)
        XCTAssertEqual(parsed.trackCount, 4)
        XCTAssertEqual(parsed.ppq, 480)
        XCTAssertEqual(parsed.tracks.count, 4)

        // Track 0: Tempo (500_000 us for 120 BPM) & Key Signature (C minor = -3 flats, minor=1)
        let metaTrack = parsed.tracks[0]
        XCTAssertTrue(metaTrack.hasEndOfTrack)
        XCTAssertEqual(metaTrack.tempoMicros, 500_000)
        XCTAssertEqual(metaTrack.keySharpsFlats, -3)
        XCTAssertEqual(metaTrack.keyMinorFlag, 1)

        // Track 1: Chords (pattern-expanded: 6 strokes/bar * 2 bars * 4 pitches = 48 note-ons!)
        let chordTrack = parsed.tracks[1]
        XCTAssertTrue(chordTrack.hasEndOfTrack)
        XCTAssertEqual(chordTrack.noteOns.count, 48)
        XCTAssertEqual(chordTrack.noteOffs.count, 48)

        // Track 2: Bass
        let bassTrack = parsed.tracks[2]
        XCTAssertTrue(bassTrack.hasEndOfTrack)
        XCTAssertEqual(bassTrack.noteOns.map(\.pitch), [36, 41])
        XCTAssertEqual(bassTrack.noteOns.map(\.tick), [0, 1920])
        XCTAssertEqual(bassTrack.noteOffs.map(\.tick), [1920, 3840])

        // Track 3: Melody
        let melodyTrack = parsed.tracks[3]
        XCTAssertTrue(melodyTrack.hasEndOfTrack)
        XCTAssertEqual(melodyTrack.noteOns.map(\.pitch), [75])
        XCTAssertEqual(melodyTrack.noteOns.map(\.tick), [480])
        XCTAssertEqual(melodyTrack.noteOffs.map(\.tick), [960])
    }

    func testExportRespectsMutePolicyAndDocumentConvenience() throws {
        let v = try vocabulary()
        let c1 = try region("r1", start: 0, length: 16, pitches: [60, 63, 67])
        let bassNotes = [try BassNote(id: "b1", startTick: 0, durationTicks: 960, pitch: 36)]
        let melodyNotes = [try MelodyNote(id: "m1", startTick: 0, durationTicks: 480, pitch: 72)]

        var synth = MixerAndSynthState()
        synth.bass.muted = true

        let doc = CodaProjectDocument(
            id: "doc-midi",
            name: "Mute Check",
            tempo: 124,
            key: MusicalKey(tonic: 0, mode: .major),
            loopSpan: try LoopSpan(start: 0, bars: 1),
            arrangementTotalSteps: 16,
            chordRegions: [c1],
            bassNotes: bassNotes,
            melodyNotes: melodyNotes,
            patternArrangement: try PatternArrangement(barCount: 1),
            synthState: synth
        )

        let mutedData = try MIDIExporter.export(document: doc, vocabulary: v)
        let mutedParsed = try parseSMF(mutedData)
        XCTAssertEqual(mutedParsed.tracks[1].noteOns.count, 3) // Chords active
        XCTAssertEqual(mutedParsed.tracks[2].noteOns.count, 0) // Bass muted!
        XCTAssertEqual(mutedParsed.tracks[3].noteOns.count, 1) // Melody active

        // When respectMutes == false, muted bass is exported
        let unmutedData = try MIDIExporter.export(
            document: doc,
            vocabulary: v,
            options: MIDIExportOptions(mutedLayers: [.bass], respectMutes: false)
        )
        let unmutedParsed = try parseSMF(unmutedData)
        XCTAssertEqual(unmutedParsed.tracks[2].noteOns.count, 1)
    }

    func testLongArrangementExportPreservesSustainedChordsAcrossFourBarChunks() throws {
        let v = try vocabulary()
        // 8-bar single sustained chord (crosses the 4-bar chunk boundary!)
        let sustained = try region("long", start: 0, length: 128, pitches: [60, 64, 67])
        let p = try Progression(totalSteps: 128, regions: [sustained], vocabulary: v)
        let arr = try PatternArrangement(barCount: 8)

        let data = try MIDIExporter.export(
            progression: p,
            patternArrangement: arr,
            tempo: 120,
            key: MusicalKey(tonic: 0, mode: .major)
        )
        let parsed = try parseSMF(data)
        // Each of the 3 pitches should have exactly 1 Note On at tick 0 and 1 Note Off at 8*1920 = 15360!
        XCTAssertEqual(parsed.tracks[1].noteOns.count, 3)
        XCTAssertEqual(parsed.tracks[1].noteOffs.count, 3)
        XCTAssertEqual(parsed.tracks[1].noteOns.map(\.tick), [0, 0, 0])
        XCTAssertEqual(parsed.tracks[1].noteOffs.map(\.tick), [15_360, 15_360, 15_360])
    }

    // MARK: - Minimal SMF Binary Parser for Test Verification

    private struct ParsedNoteEvent {
        let tick: UInt32
        let channel: UInt8
        let pitch: UInt8
        let velocity: UInt8
    }

    private struct ParsedTrack {
        var noteOns: [ParsedNoteEvent] = []
        var noteOffs: [ParsedNoteEvent] = []
        var tempoMicros: UInt32?
        var keySharpsFlats: Int8?
        var keyMinorFlag: UInt8?
        var hasEndOfTrack = false
    }

    private struct ParsedSMF {
        let format: UInt16
        let trackCount: UInt16
        let ppq: UInt16
        let tracks: [ParsedTrack]
    }

    private func parseSMF(_ data: Data) throws -> ParsedSMF {
        let bytes = Array(data)
        var cursor = 0
        func readUInt16() throws -> UInt16 {
            guard cursor + 2 <= bytes.count else { throw MusicError.invalidSpan }
            let v = (UInt16(bytes[cursor]) << 8) | UInt16(bytes[cursor + 1])
            cursor += 2
            return v
        }
        func readUInt32() throws -> UInt32 {
            guard cursor + 4 <= bytes.count else { throw MusicError.invalidSpan }
            let v = (UInt32(bytes[cursor]) << 24) | (UInt32(bytes[cursor + 1]) << 16)
                | (UInt32(bytes[cursor + 2]) << 8) | UInt32(bytes[cursor + 3])
            cursor += 4
            return v
        }
        func readVLQ() throws -> UInt32 {
            var result: UInt32 = 0
            while true {
                guard cursor < bytes.count else { throw MusicError.invalidSpan }
                let b = bytes[cursor]
                cursor += 1
                result = (result << 7) | UInt32(b & 0x7F)
                if (b & 0x80) == 0 { return result }
            }
        }

        XCTAssertEqual(Array(bytes[0..<4]), [0x4D, 0x54, 0x68, 0x64]) // MThd
        cursor = 4
        let headerLen = try readUInt32()
        XCTAssertEqual(headerLen, 6)
        let format = try readUInt16()
        let trackCount = try readUInt16()
        let ppq = try readUInt16()

        var tracks: [ParsedTrack] = []
        for _ in 0..<trackCount {
            XCTAssertEqual(Array(bytes[cursor..<(cursor + 4)]), [0x4D, 0x54, 0x72, 0x6B]) // MTrk
            cursor += 4
            let trackLen = Int(try readUInt32())
            let trackEnd = cursor + trackLen
            XCTAssertLessThanOrEqual(trackEnd, bytes.count)

            var track = ParsedTrack()
            var tick: UInt32 = 0
            while cursor < trackEnd {
                let delta = try readVLQ()
                tick += delta
                let status = bytes[cursor]
                cursor += 1
                if status == 0xFF {
                    let metaType = bytes[cursor]
                    cursor += 1
                    let len = Int(try readVLQ())
                    let payload = Array(bytes[cursor..<(cursor + len)])
                    cursor += len
                    if metaType == 0x2F && len == 0 {
                        track.hasEndOfTrack = true
                    } else if metaType == 0x51 && len == 3 {
                        track.tempoMicros = (UInt32(payload[0]) << 16) | (UInt32(payload[1]) << 8) | UInt32(payload[2])
                    } else if metaType == 0x59 && len == 2 {
                        track.keySharpsFlats = Int8(bitPattern: payload[0])
                        track.keyMinorFlag = payload[1]
                    }
                } else {
                    let hi = status & 0xF0
                    let ch = status & 0x0F
                    let d1 = bytes[cursor]
                    let d2 = bytes[cursor + 1]
                    cursor += 2
                    if hi == 0x90 && d2 > 0 {
                        track.noteOns.append(ParsedNoteEvent(tick: tick, channel: ch, pitch: d1, velocity: d2))
                    } else if hi == 0x80 || (hi == 0x90 && d2 == 0) {
                        track.noteOffs.append(ParsedNoteEvent(tick: tick, channel: ch, pitch: d1, velocity: d2))
                    }
                }
            }
            XCTAssertEqual(cursor, trackEnd)
            tracks.append(track)
        }
        XCTAssertEqual(cursor, bytes.count)
        return ParsedSMF(format: format, trackCount: trackCount, ppq: ppq, tracks: tracks)
    }
}
