import Foundation
import XCTest
import AVFoundation
import CodaMusic
import CodaNative
@testable import CodaSession

final class MusicSessionTests: XCTestCase {
    @MainActor
    func testRealCompilerSessionAndEngineWithoutEditingAuditionHistory() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: Self.self))
        let session = try MusicSession(vocabulary: vocabulary, offline: true)
        XCTAssertTrue(session.editor.progression.regions.isEmpty)
        let chord = try Chord(root: 0, qualityID: "minor7")
        let region = try ChordRegion(id: "a", chord: chord, start: 0, length: 16,
                                    pitches: [60, 63, 67, 70])
        try session.edit([.add(region)])
        try session.play()
        XCTAssertGreaterThan(try session.renderOffline(frames: 4096), 0)
        XCTAssertEqual(session.status().delivered, 4)
        let history = session.editor.progression
        try session.audition(regionID: "a")
        _ = try session.renderOffline(frames: 4096)
        XCTAssertEqual(session.editor.progression, history)
        XCTAssertTrue(session.editor.canUndo)
        try session.pause()
        _ = try session.renderOffline(frames: 512)
        XCTAssertFalse(session.status().playing != 0)
        try session.setTempo(137.3)
        try session.seek(step: 8)
        try session.play()
        _ = try session.renderOffline(frames: 512)
        XCTAssertEqual(session.status().failures, 0)
        try session.undo()
        _ = try session.renderOffline(frames: 512)
        XCTAssertTrue(session.editor.progression.regions.isEmpty)
        try session.redo()
        _ = try session.renderOffline(frames: 512)
        XCTAssertEqual(session.editor.progression, history)
        session.suspend()
        XCTAssertFalse(session.available)
        try session.restart()
        XCTAssertGreaterThan(try session.renderOffline(frames: 4096), 0)
        session.suspend()
    }

    @MainActor
    private func makeSession() throws -> MusicSession {
        try MusicSession(vocabulary: ChordVocabulary.load(in: Bundle(for: Self.self)), offline: true)
    }

    @MainActor
    private func addChord(to session: MusicSession) throws {
        try session.edit([.add(ChordRegion(id: "a", chord: Chord(root: 0, qualityID: "minor7"),
            start: 0, length: 16, pitches: [60, 63, 67, 70]))])
    }

    @MainActor
    func testRejectedRequestsPreserveStateHistoryAndPendingPlan() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try addChord(to: session)
        try session.play()
        // Fill native plan slots without rendering, then replace the facade's
        // pending plan several times. A failed edit must not supersede it.
        try session.setTempo(137.3)
        try session.setLoop(LoopSpan(start: 16, bars: 1), enabled: true)
        let span = try LoopSpan(bars: 2)
        try session.setLoop(span, enabled: true)
        try session.setTempo(145.7)
        try session.seek(step: 10)
        let history = session.editor.progression
        let controls = session.controls
        XCTAssertThrowsError(try session.setTempo(.nan))
        XCTAssertThrowsError(try session.setTempo(301))
        XCTAssertThrowsError(try session.seek(step: -1))
        var bad = controls; bad.warmth = .nan
        XCTAssertThrowsError(try session.setControls(bad))
        bad = controls; bad.preset = 3
        XCTAssertThrowsError(try session.setControls(bad))
        XCTAssertThrowsError(try session.edit([.delete(id: "a"), .delete(id: "missing")]))
        // Legal CodaMusic data can exceed the synth's twelve-voice capacity.
        let pitches = (0..<4).flatMap { octave in [48, 51, 55, 58].map { $0 + octave * 12 } }
        let tooMany = try ChordRegion(id: "dense", chord: Chord(root: 0, qualityID: "minor7"),
                                     start: 16, length: 16, pitches: pitches)
        XCTAssertThrowsError(try session.edit([.add(tooMany)])) { error in
            guard case AudioSessionError.capacity = error else { return XCTFail("Expected real voice-capacity failure: \(error)") }
        }
        XCTAssertEqual(session.editor.progression, history)
        XCTAssertTrue(session.editor.canUndo)
        XCTAssertFalse(session.editor.canRedo)
        XCTAssertEqual(session.tempo, 145.7)
        XCTAssertEqual(session.controls.tempo_bpm, Float(145.7))
        XCTAssertEqual(session.controls.warmth, controls.warmth)
        XCTAssertEqual(session.controls.preset, controls.preset)
        XCTAssertEqual(session.loop, span)
        XCTAssertTrue(session.looping && session.playing && session.available)
        _ = try session.renderOffline(frames: 1) // consumes latest native plan
        try session.setControls(session.controls) // pumps retained latest facade plan
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 10)
        XCTAssertEqual(session.status().delivered, 12) // 4 ons, then 4 offs + 4 ons
        XCTAssertEqual(session.status().failures, 0)
        XCTAssertEqual(session.status().late, 0)
        XCTAssertNil(session.error)
        try session.undo()
        _ = try session.renderOffline(frames: 1)
        XCTAssertTrue(session.editor.progression.regions.isEmpty)
        XCTAssertThrowsError(try session.edit([.add(tooMany)]))
        XCTAssertTrue(session.editor.canRedo)
        try session.redo()
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.editor.progression, history)
    }

    @MainActor
    func testInactiveValidationAndControlCapacityAreTransactional() throws {
        let session = try makeSession()
        defer { session.suspend() }
        for pitches in [[64, 60], [60, 60], [-1], [128]] {
            XCTAssertThrowsError(try session.audition(pitches: pitches))
            XCTAssertFalse(session.available) // invalid requests cannot start hardware
        }
        let pitches = (0..<4).flatMap { octave in [48, 51, 55, 58].map { $0 + octave * 12 } }
        let tooMany = try ChordRegion(id: "dense", chord: Chord(root: 0, qualityID: "minor7"),
                                     start: 0, length: 16, pitches: pitches)
        XCTAssertThrowsError(try session.edit([.add(tooMany)]))
        XCTAssertFalse(session.editor.canUndo)
        XCTAssertTrue(session.editor.progression.regions.isEmpty)
        for i in 0..<TransportConfiguration.pendingControls {
            var next = session.controls
            next.preset = UInt8(i % 3); next.muted = UInt8(i % 2)
            try session.setControls(next)
        }
        let previous = session.controls
        var rejected = previous; rejected.preset = (previous.preset + 1) % 3
        XCTAssertThrowsError(try session.setControls(rejected)) { error in
            guard case AudioSessionError.capacity = error else { return XCTFail("Expected full edge queue: \(error)") }
        }
        XCTAssertEqual(session.controls.preset, previous.preset)
        XCTAssertEqual(session.controls.muted, previous.muted)
        // Same preset/mute continuous changes still coalesce at full capacity.
        try session.setTempo(155)
        XCTAssertEqual(session.tempo, 155)
        XCTAssertEqual(session.controls.tempo_bpm, 155)
        XCTAssertFalse(session.available)
        try session.play()
        _ = try session.renderOffline(frames: 512)
        XCTAssertTrue(session.available && session.playing)
        XCTAssertEqual(session.status().failures, 0)
    }

    @MainActor
    func testSuccessfulChangesDuringActualOfflineRendering() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try addChord(to: session)
        try session.play()
        _ = try session.renderOffline(frames: 1024)
        let beforeKnob = session.status()
        var next = session.controls; next.warmth = 0.6
        try session.setControls(next)
        _ = try session.renderOffline(frames: 17)
        XCTAssertEqual(session.status().clock, beforeKnob.clock + 17)
        XCTAssertEqual(session.status().hash, beforeKnob.hash) // no reset/retrigger for knobs
        try session.setTempo(137.3)
        _ = try session.renderOffline(frames: 17)
        XCTAssertEqual(session.tempo, 137.3)
        XCTAssertEqual(session.controls.tempo_bpm, Float(137.3))
        try session.setLoop(LoopSpan(start: 16, bars: 1), enabled: true)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 0)
        try session.setLoop(LoopSpan(bars: 1), enabled: false)
        _ = try session.renderOffline(frames: 1)
        XCTAssertFalse(session.looping)
        try session.pause()
        _ = try session.renderOffline(frames: 1)
        XCTAssertFalse(session.status().playing != 0)
        try session.play()
        _ = try session.renderOffline(frames: 1)
        XCTAssertTrue(session.status().playing != 0)
        try session.stop()
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 0)
        try session.restart()
        _ = try session.renderOffline(frames: 1)
        XCTAssertTrue(session.status().playing != 0)
        XCTAssertEqual(session.status().failures, 0)
        XCTAssertEqual(session.status().late, 0)
    }

    @MainActor
    func testNaturalCompletionConfigurationAndExplicitPlayIntent() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try session.setTempo(120)
        try session.setLoop(LoopSpan(), enabled: false)
        try addChord(to: session)
        try session.play()
        // Eight bars at 120 BPM last sixteen seconds; each offline call is
        // bounded to ten seconds. This renders past the real canvas endpoint.
        _ = try session.renderOffline(frames: 480_000)
        _ = try session.renderOffline(frames: 300_000)
        let ended = session.status()
        XCTAssertEqual(ended.playing, 0)
        XCTAssertFalse(session.playing || session.renderedPlaying)
        try session.setTempo(60)
        _ = try session.renderOffline(frames: 512)
        XCTAssertEqual(session.status().hash, ended.hash)
        XCTAssertEqual(session.status().playing, 0)
        try session.play()
        _ = session.status() // old render observation must not cancel new Play
        XCTAssertTrue(session.playing)
        try session.setTempo(120)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().playing, 1)
        XCTAssertEqual(session.status().step, 0)
        XCTAssertEqual(session.status().delivered, ended.delivered + 4)
        // Also reproduce configuration after completion WITHOUT polling status.
        _ = try session.renderOffline(frames: 480_000)
        _ = try session.renderOffline(frames: 300_000)
        try session.setTempo(60)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().playing, 0)
        XCTAssertFalse(session.playing)
    }

    @MainActor
    func testInactiveScrubAndCoalescedPositionCommands() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try session.setTempo(120)
        try session.seek(step: 8)
        try addChord(to: session) // inactive edit must retain scrub
        try session.setTempo(100)
        XCTAssertFalse(session.available)
        XCTAssertEqual(session.requestedStep, 8)
        try session.play()
        _ = session.status()
        XCTAssertTrue(session.playing) // not yet acknowledged by render
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 8)
        try session.stop()
        try session.play() // no render between commands
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 0)
        XCTAssertEqual(session.status().playing, 1)
        try session.seek(step: 10)
        try session.setTempo(120)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 10)
        try session.seek(step: 6)
        try session.edit([.delete(id: "a")])
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 6)
        try session.seek(step: 2)
        try session.seek(step: 9)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 9)
        _ = try session.renderOffline(frames: 6000)
        try session.setTempo(120)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 10) // consumed seek not replayed
        session.suspend()
        XCTAssertEqual(session.requestedStep, 0)
        try session.seek(step: 5) // fresh epoch, inactive again
        try session.play()
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 5)
        try session.restart()
        try session.seek(step: 7) // later position wins over Restart's zero
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 7)
        try session.seek(step: 11)
        try session.restart() // later Restart wins
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 0)
        XCTAssertEqual(session.status().failures, 0)
    }

    @MainActor
    func testOfflinePauseResumeRetainsFractionalStepThroughConfiguration() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try session.setTempo(120) // 6000 samples per step at actual offline 48 kHz
        try session.play()
        _ = try session.renderOffline(frames: 5999)
        try session.pause()
        _ = try session.renderOffline(frames: 17)
        try session.setTempo(120)
        _ = try session.renderOffline(frames: 31)
        XCTAssertEqual(session.status().step, 0)
        try session.play()
        _ = session.status()
        XCTAssertTrue(session.playing)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 1) // resumes sample 5999, not step zero
        XCTAssertEqual(session.status().playing, 1)
    }

    @MainActor
    func testQueueFullPendingSnapshotRetainsStopAndLatestSeek() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try session.seek(step: 8)
        try addChord(to: session)
        try session.play()
        _ = try session.renderOffline(frames: 1)
        try session.setTempo(120)
        try session.setTempo(121) // fills two queued slots beside active slot
        try session.stop() // facade must retain unpublished position zero
        try session.play()
        try session.edit([.delete(id: "a")])
        try session.setTempo(122) // replaces pending snapshot, retains stop zero
        _ = try session.renderOffline(frames: 1)
        try session.setControls(session.controls) // deterministic control-side pump
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 0)
        XCTAssertEqual(session.status().playing, 1)
        try session.setTempo(123)
        try session.setTempo(124)
        try session.seek(step: 3) // full native queue, pending facade position
        try session.seek(step: 10)
        try session.undo()
        try session.setTempo(120)
        XCTAssertThrowsError(try session.setTempo(.nan))
        _ = try session.renderOffline(frames: 1)
        try session.setControls(session.controls)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().step, 10)
        XCTAssertEqual(session.status().failures, 0)
        XCTAssertNil(session.error)
    }

    @MainActor
    func testProductionLifecycleRoutingRejectsStartupAndStaleNotifications() throws {
        let session = try makeSession()
        defer { session.suspend() }
        try session.play()
        let epoch = session.lifecycleEpoch
        // Direct invocation of the same MainActor router used by observers:
        // deterministic delivery, no sleeps or timing assumptions.
        session.handleAudioNotification(name: AVAudioSession.routeChangeNotification,
            reason: AVAudioSession.RouteChangeReason.categoryChange.rawValue, epoch: epoch)
        session.handleAudioNotification(name: AVAudioSession.interruptionNotification,
            reason: AVAudioSession.InterruptionType.ended.rawValue, epoch: epoch)
        session.handleAudioNotification(name: AVAudioSession.interruptionNotification, reason: nil, epoch: epoch)
        session.handleAudioNotification(name: AVAudioSession.routeChangeNotification, reason: 999, epoch: epoch)
        session.handleAudioNotification(name: .AVAudioEngineConfigurationChange, reason: nil, epoch: epoch)
        XCTAssertTrue(session.available && session.playing) // live matching-rate engine
        _ = try session.renderOffline(frames: 512)
        let retiredEngine = session.configurationOwner
        session.handleAudioNotification(name: AVAudioSession.interruptionNotification,
            reason: AVAudioSession.InterruptionType.began.rawValue, epoch: epoch)
        XCTAssertFalse(session.available || session.playing)
        session.handleAudioNotification(name: AVAudioSession.interruptionNotification,
            reason: AVAudioSession.InterruptionType.ended.rawValue, epoch: epoch)
        XCTAssertFalse(session.available) // never auto-restart
        try session.play()
        XCTAssertFalse(session.configurationOwner === retiredEngine)
        session.handleAudioNotification(name: .AVAudioEngineConfigurationChange, reason: nil, epoch: epoch)
        session.handleAudioNotification(name: AVAudioSession.routeChangeNotification,
            reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, epoch: epoch)
        XCTAssertTrue(session.available) // old callbacks cannot close replacement
        // Apple config changes stop/uninitialize the engine. Exercise actual
        // invalidation of this adapter rather than inventing a stopped mock.
        let engine = try XCTUnwrap(session.configurationOwner as? AVAudioEngine)
        engine.stop()
        session.handleAudioNotification(name: .AVAudioEngineConfigurationChange,
            reason: nil, epoch: session.lifecycleEpoch)
        XCTAssertFalse(session.available)
        for reason in [AVAudioSession.RouteChangeReason.newDeviceAvailable, .oldDeviceUnavailable,
                       .override, .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange] {
            try session.play()
            session.handleAudioNotification(name: AVAudioSession.routeChangeNotification,
                reason: reason.rawValue, epoch: session.lifecycleEpoch)
            XCTAssertFalse(session.available, "Expected explicit suspension for \(reason)")
        }
    }

}
