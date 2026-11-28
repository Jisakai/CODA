import Foundation

public struct MIDIExportOptions: Equatable, Sendable {
    public var mutedLayers: Set<MusicLayer>
    public var respectMutes: Bool
    public var loopRange: LoopSpan?
    public var includeEmptyTracks: Bool
    public var chordsChannel: UInt8
    public var bassChannel: UInt8
    public var melodyChannel: UInt8

    public init(
        mutedLayers: Set<MusicLayer> = [],
        respectMutes: Bool = true,
        loopRange: LoopSpan? = nil,
        includeEmptyTracks: Bool = true,
        chordsChannel: UInt8 = 0,
        bassChannel: UInt8 = 1,
        melodyChannel: UInt8 = 2
    ) {
        self.mutedLayers = mutedLayers
        self.respectMutes = respectMutes
        self.loopRange = loopRange
        self.includeEmptyTracks = includeEmptyTracks
        self.chordsChannel = chordsChannel & 0x0F
        self.bassChannel = bassChannel & 0x0F
        self.melodyChannel = melodyChannel & 0x0F
    }
}

/// Pure-Swift Standard MIDI File (SMF Format 1, 480 PPQ) generator (SPEC §19).
public enum MIDIExporter {
    public static let ticksPerQuarterNote: UInt16 = UInt16(MusicDefaults.ticksPerBeat)
    private static let exportSampleRate: Double = 48_000.0
    private static let maxBarsPerExpansionChunk = 4

    public static func export(
        document: CodaProjectDocument,
        vocabulary: ChordVocabulary,
        options: MIDIExportOptions? = nil
    ) throws -> Data {
        let progression = try document.makeProgression(vocabulary: vocabulary)
        let bass = try document.makeBassTrack()
        let melody = try document.makeMelodyTrack()
        let effectiveOptions = options ?? MIDIExportOptions(
            mutedLayers: document.synthState.mutedLayers,
            respectMutes: true
        )
        return try export(
            progression: progression,
            patternArrangement: document.patternArrangement,
            bass: bass,
            melody: melody,
            tempo: document.tempo,
            key: document.key,
            projectName: document.name,
            options: effectiveOptions
        )
    }

    public static func export(
        progression: Progression,
        patternArrangement: PatternArrangement,
        bass: BassTrack = .empty,
        melody: MelodyTrack = .empty,
        tempo: Double,
        key: MusicalKey,
        projectName: String = "coda",
        options: MIDIExportOptions = MIDIExportOptions()
    ) throws -> Data {
        guard tempo.isFinite, tempo > 0 else { throw MusicError.invalidTempo }
        let totalBars = progression.totalSteps / MusicDefaults.stepsPerBar
        let span = try options.loopRange ?? LoopSpan(start: 0, bars: totalBars)
        guard span.end <= progression.totalSteps else { throw MusicError.invalidSpan }

        var tracks: [Data] = []
        tracks.append(buildMetaTrack(tempo: tempo, key: key, projectName: projectName))

        let chordsMuted = options.respectMutes && options.mutedLayers.contains(.chords)
        let chordEvents: [RawMIDIEvent]
        if chordsMuted {
            chordEvents = []
        } else {
            chordEvents = try expandChordTrackEvents(
                progression: progression,
                patternArrangement: patternArrangement,
                tempo: tempo,
                span: span,
                channel: options.chordsChannel
            )
        }
        if options.includeEmptyTracks || !chordEvents.isEmpty {
            tracks.append(buildNoteTrack(name: "Chords", events: chordEvents))
        }

        let bassMuted = options.respectMutes && options.mutedLayers.contains(.bass)
        let bassEvents: [RawMIDIEvent]
        if bassMuted {
            bassEvents = []
        } else {
            bassEvents = buildLinearNoteEvents(
                items: bass.notes.map { ($0.startTick, $0.endTick, $0.pitch, $0.velocity) },
                span: span,
                channel: options.bassChannel
            )
        }
        if options.includeEmptyTracks || !bassEvents.isEmpty {
            tracks.append(buildNoteTrack(name: "Bass", events: bassEvents))
        }

        let melodyMuted = options.respectMutes && options.mutedLayers.contains(.melody)
        let melodyEvents: [RawMIDIEvent]
        if melodyMuted {
            melodyEvents = []
        } else {
            melodyEvents = buildLinearNoteEvents(
                items: melody.notes.map { ($0.effectiveStartTick, $0.effectiveEndTick, $0.pitch, $0.velocity) },
                span: span,
                channel: options.melodyChannel
            )
        }
        if options.includeEmptyTracks || !melodyEvents.isEmpty {
            tracks.append(buildNoteTrack(name: "Melody", events: melodyEvents))
        }

        var output = Data()
        // MThd header: format 1, track count, 480 PPQ
        output.append(contentsOf: [0x4D, 0x54, 0x68, 0x64]) // "MThd"
        appendUInt32BE(6, to: &output)
        appendUInt16BE(1, to: &output) // Format 1
        appendUInt16BE(UInt16(tracks.count), to: &output)
        appendUInt16BE(ticksPerQuarterNote, to: &output)

        for track in tracks {
            output.append(track)
        }
        return output
    }

    // MARK: - VLQ & Binary Encoding

    /// Standard MIDI Variable-Length Quantity encoding.
    public static func encodeVLQ(_ value: UInt32) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return bytes.reversed()
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    // MARK: - Track Builders

    private struct RawMIDIEvent {
        let tick: UInt32
        /// Ordering priority at equal ticks: meta (0) < noteOff (1) < noteOn (2).
        let sortOrder: UInt8
        let pitch: UInt8
        let bytes: [UInt8]
    }

    private static func buildMetaTrack(tempo: Double, key: MusicalKey, projectName: String) -> Data {
        var events: [RawMIDIEvent] = []

        // Track name (0xFF 0x03)
        let nameBytes = Array(projectName.utf8)
        events.append(RawMIDIEvent(
            tick: 0,
            sortOrder: 0,
            pitch: 0,
            bytes: [0xFF, 0x03] + encodeVLQ(UInt32(nameBytes.count)) + nameBytes
        ))

        // Time signature: 4/4 (0xFF 0x58 0x04 0x04 0x02 0x18 0x08)
        events.append(RawMIDIEvent(
            tick: 0,
            sortOrder: 0,
            pitch: 0,
            bytes: [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]
        ))

        // Tempo: microseconds per quarter note (0xFF 0x51 0x03 t2 t1 t0)
        let rawMicros = (60_000_000.0 / tempo).rounded()
        let clampedMicros = UInt32(max(1.0, min(Double(0x00FF_FFFF), rawMicros)))
        events.append(RawMIDIEvent(
            tick: 0,
            sortOrder: 0,
            pitch: 0,
            bytes: [
                0xFF, 0x51, 0x03,
                UInt8((clampedMicros >> 16) & 0xFF),
                UInt8((clampedMicros >> 8) & 0xFF),
                UInt8(clampedMicros & 0xFF)
            ]
        ))

        // Key signature: (0xFF 0x59 0x02 sf mi)
        let sf = keySignatureSharpsFlats(key: key)
        let mi: UInt8 = key.mode == .major ? 0x00 : 0x01
        events.append(RawMIDIEvent(
            tick: 0,
            sortOrder: 0,
            pitch: 0,
            bytes: [0xFF, 0x59, 0x02, UInt8(bitPattern: sf), mi]
        ))

        return wrapTrackChunk(events: events)
    }

    private static func buildNoteTrack(name: String, events: [RawMIDIEvent]) -> Data {
        var all: [RawMIDIEvent] = []
        let nameBytes = Array(name.utf8)
        all.append(RawMIDIEvent(
            tick: 0,
            sortOrder: 0,
            pitch: 0,
            bytes: [0xFF, 0x03] + encodeVLQ(UInt32(nameBytes.count)) + nameBytes
        ))
        all.append(contentsOf: events)
        return wrapTrackChunk(events: all)
    }

    private static func wrapTrackChunk(events: [RawMIDIEvent]) -> Data {
        let sorted = events.sorted { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.pitch < b.pitch
        }

        var payload = Data()
        var currentTick: UInt32 = 0
        for event in sorted {
            let delta = event.tick >= currentTick ? event.tick - currentTick : 0
            currentTick = max(currentTick, event.tick)
            payload.append(contentsOf: encodeVLQ(delta))
            payload.append(contentsOf: event.bytes)
        }

        // End of Track marker (delta 0, 0xFF 0x2F 0x00)
        payload.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])

        var chunk = Data()
        chunk.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B]) // "MTrk"
        appendUInt32BE(UInt32(payload.count), to: &chunk)
        chunk.append(payload)
        return chunk
    }

    // MARK: - Musical Event Extraction

    private static func expandChordTrackEvents(
        progression: Progression,
        patternArrangement: PatternArrangement,
        tempo: Double,
        span: LoopSpan,
        channel: UInt8
    ) throws -> [RawMIDIEvent] {
        let ticksPerSecond = (tempo / 60.0) * Double(MusicDefaults.ticksPerBeat)
        let spanStartBar = span.start / MusicDefaults.stepsPerBar
        let spanBars = span.length / MusicDefaults.stepsPerBar
        let spanEndBar = spanStartBar + spanBars

        var events: [RawMIDIEvent] = []
        // Track notes carried across chunk boundaries by continuationKey -> pitch.
        var openContinuations: [String: UInt8] = [:]

        var bar = spanStartBar
        while bar < spanEndBar {
            let chunkBars = min(maxBarsPerExpansionChunk, spanEndBar - bar)
            let chunkSpan = try LoopSpan(start: bar * MusicDefaults.stepsPerBar, bars: chunkBars)
            let carryIn = bar > spanStartBar
            let carryOut = (bar + chunkBars) < spanEndBar

            let compiled = try PatternEventCompiler.compile(
                progression,
                arrangement: patternArrangement,
                tempo: tempo,
                sampleRate: exportSampleRate,
                loop: chunkSpan,
                cycleIndex: 0,
                forcePerformance: true,
                carryIn: carryIn,
                carryOut: carryOut
            )

            guard case .pattern(let loop) = compiled else {
                bar += chunkBars
                continue
            }

            let chunkBaseTick = UInt32((bar - spanStartBar) * MusicDefaults.stepsPerBar * MusicDefaults.ticksPerStep)
            var matchedCarryInKeys = Set<String>()
            var nextOpenContinuations: [String: UInt8] = [:]
            var activeNoteOnTick: [PatternNoteToken: UInt32] = [:]

            for event in loop.events {
                let relTick = UInt32(max(0, Int((Double(event.sampleOffset) / exportSampleRate * ticksPerSecond).rounded())))
                let absTick = chunkBaseTick + relTick

                switch event.kind {
                case .noteOn:
                    activeNoteOnTick[event.instanceToken] = absTick
                    if event.continuesFromPrevious, let key = event.continuationKey, openContinuations[key] != nil {
                        matchedCarryInKeys.insert(key)
                        continue
                    }
                    let vel = UInt8(max(1, min(127, Int((event.effectiveVelocity * 127.0).rounded()))))
                    events.append(RawMIDIEvent(
                        tick: absTick,
                        sortOrder: 2,
                        pitch: event.pitch,
                        bytes: [0x90 | channel, event.pitch & 0x7F, vel]
                    ))

                case .noteOff:
                    if event.continuesIntoNext, let key = event.continuationKey {
                        nextOpenContinuations[key] = event.pitch
                        continue
                    }
                    let onTick = activeNoteOnTick[event.instanceToken] ?? absTick
                    let offTick = max(onTick + 1, absTick)
                    events.append(RawMIDIEvent(
                        tick: offTick,
                        sortOrder: 1,
                        pitch: event.pitch,
                        bytes: [0x80 | channel, event.pitch & 0x7F, 0x00]
                    ))
                }
            }

            // Close any previously open continuation that was not picked up in this chunk.
            for (key, pitch) in openContinuations where !matchedCarryInKeys.contains(key) {
                events.append(RawMIDIEvent(
                    tick: chunkBaseTick,
                    sortOrder: 1,
                    pitch: pitch,
                    bytes: [0x80 | channel, pitch & 0x7F, 0x00]
                ))
            }

            openContinuations = nextOpenContinuations
            bar += chunkBars
        }

        // Safety flush at span end if anything remained open.
        let spanEndTick = UInt32(span.length * MusicDefaults.ticksPerStep)
        for (_, pitch) in openContinuations {
            events.append(RawMIDIEvent(
                tick: spanEndTick,
                sortOrder: 1,
                pitch: pitch,
                bytes: [0x80 | channel, pitch & 0x7F, 0x00]
            ))
        }

        return events
    }

    private static func buildLinearNoteEvents(
        items: [(startTick: Int, endTick: Int, pitch: Int, velocity: Int)],
        span: LoopSpan,
        channel: UInt8
    ) -> [RawMIDIEvent] {
        let spanStartTick = span.start * MusicDefaults.ticksPerStep
        let spanEndTick = span.end * MusicDefaults.ticksPerStep
        var events: [RawMIDIEvent] = []

        for item in items {
            let lo = max(spanStartTick, item.startTick)
            let hi = min(spanEndTick, item.endTick)
            guard hi > lo else { continue }
            let onTick = UInt32(lo - spanStartTick)
            let offTick = UInt32(hi - spanStartTick)
            let pitch = UInt8(max(0, min(127, item.pitch)))
            let vel = UInt8(max(1, min(127, item.velocity)))

            events.append(RawMIDIEvent(
                tick: onTick,
                sortOrder: 2,
                pitch: pitch,
                bytes: [0x90 | channel, pitch, vel]
            ))
            events.append(RawMIDIEvent(
                tick: max(onTick + 1, offTick),
                sortOrder: 1,
                pitch: pitch,
                bytes: [0x80 | channel, pitch, 0x00]
            ))
        }
        return events
    }

    private static func keySignatureSharpsFlats(key: MusicalKey) -> Int8 {
        let tonic = (key.tonic % 12 + 12) % 12
        switch key.mode {
        case .major:
            // C=0, Db=-5, D=2, Eb=-3, E=4, F=-1, F#=6, G=1, Ab=-4, A=3, Bb=-2, B=5
            let table: [Int8] = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
            return table[tonic]
        case .naturalMinor:
            // Cm=-3, C#m=4, Dm=-1, Ebm=-6, Em=1, Fm=-4, F#m=3, Gm=-2, G#m=5, Am=0, Bbm=-5, Bm=2
            let table: [Int8] = [-3, 4, -1, -6, 1, -4, 3, -2, 5, 0, -5, 2]
            return table[tonic]
        }
    }
}
