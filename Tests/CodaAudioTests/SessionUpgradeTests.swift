import Foundation
import XCTest
import CodaMusic
import CodaNative
@testable import CodaSession

final class SessionUpgradeTests: XCTestCase {
    @MainActor
    private func makeVocabulary() throws -> ChordVocabulary {
        try ChordVocabulary.load(in: Bundle(for: Self.self))
    }

    @MainActor
    private func makeSession() throws -> MusicSession {
        try MusicSession(vocabulary: makeVocabulary(), offline: true)
    }

    // MARK: - 3-Layer Mixer Controls & Multi-Layer Audio

    @MainActor
    func testThreeLayerMixerControlsSoloMuteAndSharedFX() throws {
        let session = try makeSession()
        defer { session.suspend() }

        var bassCtrl = session.layerControls(for: .bass)
        bassCtrl.preset = 1
        bassCtrl.level = 0.75
        bassCtrl.cutoff = 0.42
        session.setLayerControls(bassCtrl, for: .bass)

        XCTAssertEqual(session.layerControls(for: .bass).preset, 1)
        XCTAssertEqual(session.layerControls(for: .bass).level, 0.75, accuracy: 1e-5)
        XCTAssertEqual(session.layerControls(for: .bass).cutoff, 0.42, accuracy: 1e-5)

        var chordsCtrl = session.layerControls(for: .chords)
        chordsCtrl.warmth = 0.65
        session.setLayerControls(chordsCtrl, for: .chords)
        XCTAssertEqual(session.controls.warmth, 0.65, accuracy: 1e-5)

        session.setSharedFX(delay: 0.35, reverb: 0.55)
        XCTAssertEqual(session.mixerControls.delay_amount, 0.35, accuracy: 1e-5)
        XCTAssertEqual(session.mixerControls.reverb_amount, 0.55, accuracy: 1e-5)
        XCTAssertEqual(session.controls.delay_amount, 0.35, accuracy: 1e-5)
        XCTAssertEqual(session.controls.reverb_amount, 0.55, accuracy: 1e-5)

        session.setLayerMuted(true, for: .melody)
        XCTAssertTrue(session.isLayerMuted(.melody))
        XCTAssertFalse(session.isLayerMuted(.chords))
        XCTAssertFalse(session.isLayerMuted(.bass))

        session.soloLayer(.bass)
        XCTAssertTrue(session.isLayerMuted(.chords))
        XCTAssertFalse(session.isLayerMuted(.bass))
        XCTAssertTrue(session.isLayerMuted(.melody))

        session.unmuteAllLayers()
        XCTAssertFalse(session.isLayerMuted(.chords))
        XCTAssertFalse(session.isLayerMuted(.bass))
        XCTAssertFalse(session.isLayerMuted(.melody))

        // Audition on each layer and render multi-layer offline audio.
        try session.edit([.add(ChordRegion(
            id: "c1",
            chord: Chord(root: 0, qualityID: "minor7"),
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        let melNote = try MelodyNote(id: "m1", startTick: 0, durationTicks: 480, pitch: 72, velocity: 100)
        session.setMelodyTrack(try MelodyTrack(notes: [melNote]))

        session.audition(pitches: [48], layer: .bass)
        XCTAssertTrue(session.available)
        try session.play()
        let energy = try session.renderOffline(frames: 4096)
        XCTAssertGreaterThan(energy, 0)
        XCTAssertEqual(session.status().failures, 0)
        XCTAssertNil(session.error)
    }

    // MARK: - Stage 1 Loop-Disable Rebase

    @MainActor
    func testLoopDisableAfterLaterCycleRebasesCleanly() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try session.edit([.add(ChordRegion(
            id: "loop-chord",
            chord: Chord(root: 0, qualityID: "minor7"),
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        try session.setTempo(120)
        try session.setLoop(LoopSpan(bars: 8), enabled: true)
        try session.play()

        // Advance well past 8 bars while looping so native cycle >= 8.
        for _ in 0..<20 {
            _ = try session.renderOffline(frames: 48_000)
        }
        XCTAssertGreaterThanOrEqual(session.status().cycle, 8)

        // Disable looping without changing span length (8 bars -> 8 bars).
        try session.setLoop(LoopSpan(bars: 8), enabled: false)
        for _ in 0..<4 {
            _ = try session.renderOffline(frames: 512)
        }
        XCTAssertFalse(session.looping)
        XCTAssertLessThan(session.status().cycle, 8)
        XCTAssertEqual(session.status().failures, 0)
        XCTAssertNil(session.error)
    }

    // MARK: - BassFollower Sync + Atomic Undo

    @MainActor
    func testBassFollowerAutoSeedsReconcilesAndUndoesAtomically() throws {
        let session = try makeSession()
        defer { session.suspend() }
        XCTAssertTrue(session.bassTrack.notes.isEmpty)

        // First chord seeds bass root C2 (36).
        let cMinor = try Chord(root: 0, qualityID: "minor7")
        try session.edit([.add(ChordRegion(
            id: "r1",
            chord: cMinor,
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        XCTAssertEqual(session.bassTrack.notes.count, 1)
        XCTAssertEqual(session.bassTrack.notes[0].pitch % 12, 0)

        // Swap chord root to G -> bass follows to G in the same transaction.
        let gDom = try Chord(root: 7, qualityID: "dominant7")
        try session.edit([.swap(id: "r1", chord: gDom)])
        XCTAssertEqual(session.editor.progression.regions[0].chord, gDom)
        XCTAssertEqual(session.bassTrack.notes.count, 1)
        XCTAssertEqual(session.bassTrack.notes[0].pitch % 12, 7)

        // ONE undo restores BOTH chord and bass back to C.
        try session.undo()
        XCTAssertEqual(session.editor.progression.regions[0].chord, cMinor)
        XCTAssertEqual(session.bassTrack.notes.count, 1)
        XCTAssertEqual(session.bassTrack.notes[0].pitch % 12, 0)

        // ONE more undo restores empty progression and empty bass.
        try session.undo()
        XCTAssertTrue(session.editor.progression.regions.isEmpty)
        XCTAssertTrue(session.bassTrack.notes.isEmpty)

        // Redo twice brings back G chord + G bass.
        try session.redo()
        XCTAssertEqual(session.bassTrack.notes[0].pitch % 12, 0)
        try session.redo()
        XCTAssertEqual(session.bassTrack.notes[0].pitch % 12, 7)
    }

    // MARK: - ProjectHubStore Round-Trip & Autosave Recovery

    @MainActor
    func testProjectHubStoreRoundTripAndAutosaveRecovery() throws {
        let vocab = try makeVocabulary()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coda-hub-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProjectHubStore(directory: tempDir, vocabulary: vocab)
        let session = try makeSession()
        defer { session.suspend() }

        try session.edit([.add(ChordRegion(
            id: "hub-c1",
            chord: Chord(root: 0, qualityID: "minor7"),
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        try session.setTempo(118)
        let mel = try MelodyNote(id: "hub-m1", startTick: 0, durationTicks: 480, pitch: 75)
        session.setMelodyTrack(try MelodyTrack(notes: [mel]))

        // Autosave write & recovery
        let autosaveDoc = session.makeProjectDocument()
        store.writeAutosave(autosaveDoc)
        let recovered = try XCTUnwrap(store.loadAutosaveRecovery())
        XCTAssertEqual(recovered.id, autosaveDoc.id)
        XCTAssertEqual(recovered.tempo, 118)
        XCTAssertEqual(recovered.chordRegions.count, 1)
        XCTAssertEqual(recovered.melodyNotes.count, 1)

        // Save clears autosave and indexes project with String ID & clean summary
        let summary = try store.save(autosaveDoc)
        XCTAssertEqual(summary.id, autosaveDoc.id)
        XCTAssertEqual(store.activeProjectID, autosaveDoc.id)
        XCTAssertEqual(summary.keyDisplayName, "C Min")
        XCTAssertFalse(summary.previewChordNames.isEmpty)
        XCTAssertNil(store.loadAutosaveRecovery())

        // Rename, duplicate, export/import, load into fresh session, delete
        try store.rename(id: autosaveDoc.id, to: "Midnight Sketch")
        let loaded = try store.load(id: autosaveDoc.id)
        XCTAssertEqual(loaded.name, "Midnight Sketch")

        let copy = try store.duplicate(id: autosaveDoc.id)
        XCTAssertNotEqual(copy.id, autosaveDoc.id)
        XCTAssertEqual(copy.name, "Midnight Sketch Copy")

        let exported = try store.exportJSONData(for: loaded)
        let imported = try store.importJSONData(exported)
        XCTAssertNotEqual(imported.id, loaded.id)

        let freshSession = try makeSession()
        defer { freshSession.suspend() }
        try freshSession.loadProjectDocument(loaded)
        XCTAssertEqual(freshSession.projectID, loaded.id)
        XCTAssertEqual(freshSession.projectName, "Midnight Sketch")
        XCTAssertEqual(freshSession.tempo, 118)
        XCTAssertEqual(freshSession.editor.progression.regions.count, 1)
        XCTAssertEqual(freshSession.melodyTrack.notes.count, 1)

        try store.delete(id: copy.id)
        XCTAssertFalse(store.projects.contains { $0.id == copy.id })
    }

    // MARK: - A/B Snapshot Toggle

    @MainActor
    func testABSnapshotCaptureAndToggle() throws {
        let session = try makeSession()
        defer { session.suspend() }

        // State A
        try session.setTempo(110)
        try session.setKey(MusicalKey(tonic: 0, mode: .naturalMinor))
        try session.edit([.add(ChordRegion(
            id: "ab-a",
            chord: Chord(root: 0, qualityID: "minor7"),
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        session.captureABSnapshot()
        XCTAssertNotNil(session.abSnapshot)
        XCTAssertFalse(session.showingSnapshotB)

        // Mutate into State B
        try session.setTempo(132)
        try session.setKey(MusicalKey(tonic: 7, mode: .major))
        try session.edit([.swap(id: "ab-a", chord: Chord(root: 7, qualityID: "major7"))])

        // Toggle -> restores A
        try session.toggleABSnapshot()
        XCTAssertTrue(session.showingSnapshotB)
        XCTAssertEqual(session.tempo, 110)
        XCTAssertEqual(session.key, MusicalKey(tonic: 0, mode: .naturalMinor))
        XCTAssertEqual(session.editor.progression.regions[0].chord.root, 0)

        // Toggle back -> restores B
        try session.toggleABSnapshot()
        XCTAssertFalse(session.showingSnapshotB)
        XCTAssertEqual(session.tempo, 132)
        XCTAssertEqual(session.key, MusicalKey(tonic: 7, mode: .major))
        XCTAssertEqual(session.editor.progression.regions[0].chord.root, 7)
    }

    // MARK: - Transpose, Relative Key, + Bar, Ghost Chords, Clear Layer

    @MainActor
    func testTransposeRelativeKeyDuplicateBarAndGhostChords() throws {
        let session = try makeSession()
        defer { session.suspend() }

        try session.edit([.add(ChordRegion(
            id: "t1",
            chord: Chord(root: 0, qualityID: "minor7"),
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        let mel = try MelodyNote(id: "tm1", startTick: 0, durationTicks: 480, pitch: 72)
        session.setMelodyTrack(try MelodyTrack(notes: [mel]))

        let initialBassPitch = session.bassTrack.notes[0].pitch

        // Transpose +2 semitones across key, chords, bass, melody in one undo step
        try session.transposeAll(semitones: 2)
        XCTAssertEqual(session.key, MusicalKey(tonic: 2, mode: .naturalMinor))
        XCTAssertEqual(session.editor.progression.regions[0].chord.root, 2)
        XCTAssertEqual(session.editor.progression.regions[0].pitches, [62, 65, 69, 72])
        XCTAssertEqual(session.bassTrack.notes[0].pitch, initialBassPitch + 2)
        XCTAssertEqual(session.melodyTrack.notes[0].pitch, 74)

        try session.undo()
        XCTAssertEqual(session.key, MusicalKey(tonic: 0, mode: .naturalMinor))
        XCTAssertEqual(session.editor.progression.regions[0].chord.root, 0)
        XCTAssertEqual(session.bassTrack.notes[0].pitch, initialBassPitch)
        XCTAssertEqual(session.melodyTrack.notes[0].pitch, 72)

        // Relative key switch: C Minor (0) <-> Eb Major (3)
        try session.switchRelativeKey()
        XCTAssertEqual(session.key, MusicalKey(tonic: 3, mode: .major))
        try session.switchRelativeKey()
        XCTAssertEqual(session.key, MusicalKey(tonic: 0, mode: .naturalMinor))

        // Duplicate bar 0 -> grows by 1 bar, duplicates chord/bass/melody, undoable
        let beforeSteps = session.editor.progression.totalSteps
        try session.duplicateBar(at: 0)
        XCTAssertEqual(session.editor.progression.totalSteps, beforeSteps + MusicDefaults.stepsPerBar)
        XCTAssertEqual(session.editor.progression.regions.count, 2)
        XCTAssertEqual(session.bassTrack.notes.count, 2)
        XCTAssertEqual(session.melodyTrack.notes.count, 2)

        try session.undo()
        XCTAssertEqual(session.editor.progression.totalSteps, beforeSteps)
        XCTAssertEqual(session.editor.progression.regions.count, 1)
        XCTAssertEqual(session.bassTrack.notes.count, 1)
        XCTAssertEqual(session.melodyTrack.notes.count, 1)

        // Accept ghost chords: 1 undo step, never overwrites melody
        let savedMelody = session.melodyTrack
        try session.acceptGhostChords([
            (startStep: 16, lengthSteps: 16, chord: try Chord(root: 5, qualityID: "minor7"), pitches: [65, 68, 72, 75]),
            (startStep: 32, lengthSteps: 16, chord: try Chord(root: 7, qualityID: "dominant7"), pitches: [67, 71, 74, 77])
        ])
        XCTAssertEqual(session.editor.progression.regions.count, 3)
        XCTAssertEqual(session.melodyTrack, savedMelody)

        try session.undo()
        XCTAssertEqual(session.editor.progression.regions.count, 1)
        XCTAssertEqual(session.melodyTrack, savedMelody)
    }

    // MARK: - MIDI Export

    @MainActor
    func testMIDIExportRespectsMuteOption() throws {
        let session = try makeSession()
        defer { session.suspend() }

        try session.edit([.add(ChordRegion(
            id: "midi-c1",
            chord: Chord(root: 0, qualityID: "minor7"),
            start: 0,
            length: 16,
            pitches: [60, 63, 67, 70]
        ))])
        let mel = try MelodyNote(id: "midi-m1", startTick: 0, durationTicks: 480, pitch: 72)
        session.setMelodyTrack(try MelodyTrack(notes: [mel]))

        session.setLayerMuted(true, for: .melody)
        let respectingMute = try session.exportMIDI(includeMutedLayers: false)
        let includingMuted = try session.exportMIDI(includeMutedLayers: true)

        XCTAssertEqual(Array(respectingMute.prefix(4)), [0x4D, 0x54, 0x68, 0x64]) // "MThd"
        XCTAssertEqual(Array(includingMuted.prefix(4)), [0x4D, 0x54, 0x68, 0x64])
        XCTAssertGreaterThan(includingMuted.count, respectingMute.count)
    }
}
