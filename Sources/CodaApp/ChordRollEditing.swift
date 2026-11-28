import Foundation
import SwiftUI
import CodaMusic
import CodaInteraction
import CodaSession

enum PianoRollTool: String { case drawErase, razor, selection }
struct RollNoteReference: Hashable {
    let regionID: String
    let noteID: String
}
struct CopiedRollNote {
    let offsetTicks: Int
    let durationTicks: Int
    let pitch: Int
    let velocity: Int
    let slide: Bool
}
struct PianoRollDraft {
    enum Operation {
        case draw(regionID: String, noteID: String)
        case transform(Set<RollNoteReference>, resize: Bool)
        case marquee
        case razor
    }
    let origin: CGPoint
    let original: [ChordRegion]
    let operation: Operation
    var preview: [ChordRegion]
    var cuts: [String: [String: Int]] = [:]
    var lastPoint: CGPoint
}

struct BassRollDraft {
    enum Operation {
        case draw(noteID: String)
        case transform(Set<String>, resize: Bool)
        case marquee
        case razor
    }
    let origin: CGPoint
    let original: [BassNote]
    let operation: Operation
    var preview: [BassNote]
    var cuts: [String: Int] = [:]
    var lastPoint: CGPoint
}

struct MelodyRollDraft {
    enum Operation {
        case draw(noteID: String)
        case transform(Set<String>, resize: Bool)
        case marquee
        case razor
    }
    let origin: CGPoint
    let original: [MelodyNote]
    let operation: Operation
    var preview: [MelodyNote]
    var cuts: [String: Int] = [:]
    var lastPoint: CGPoint
}

struct ObjectHoldCommand {
    let title: String
    let symbol: String
    var enabled = true
    var destructive = false
}

/// Pencil ingress calls these methods; no SwiftUI finger gesture edits music.
extension CodaEditorStore {
    var displayedRegions: [ChordRegion] {
        if let draft = rollDraft { return draft.preview }
        if let preview = chordRollPreview { return regions.map { $0.id == preview.id ? preview : $0 } }
        return regions
    }

    var displayedBassNotes: [BassNote] {
        if let draft = bassRollDraft { return draft.preview }
        return bassNotes
    }

    var displayedMelodyNotes: [MelodyNote] {
        if let draft = melodyRollDraft { return draft.preview }
        if let preview = melodyNudgePreview {
            return melodyNotes.map { $0.id == preview.id ? preview : $0 }
        }
        return melodyNotes
    }

    var hasActiveRollDraft: Bool {
        rollDraft != nil || bassRollDraft != nil || melodyRollDraft != nil
    }

    var visibleBars: Range<Int> { viewport.visibleBars(in: Double(contentWidth)) }
    var visibleRegions: [ChordRegion] {
        let range = viewport.visibleSteps(in: Double(contentWidth))
        return displayedRegions.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
    }

    func growArrangementForViewport() {
        let unit = viewport.stepWidth(in: Double(contentWidth))
        guard unit > 0, let end = Int(exactly: ceil((viewport.horizontalOffset + Double(contentWidth)) / unit)),
              end < Int.max - MusicDefaults.stepsPerBar * 2 else { return }
        let requested = end + MusicDefaults.stepsPerBar * 2
        guard requested > totalSteps else { viewport.extend(through: totalSteps); return }
        do {
            try session?.extendArrangement(through: requested)
            viewport.extend(through: totalSteps)
        } catch { inlineError = String(describing: error) }
    }

    func noteFrame(_ note: RollNote, in region: ChordRegion) -> CGRect {
        let step = Double(region.start) + Double(note.startTick) / Double(MusicDefaults.ticksPerStep)
        return CGRect(x: CGFloat(viewport.x(forStep: step, in: Double(contentWidth))) + CodaDesignTokens.Geometry.pitchGutterWidth,
            y: CGFloat(viewport.y(forMIDI: note.pitch)) + rollTop,
            width: max(2, CGFloat(Double(note.durationTicks) / Double(MusicDefaults.ticksPerStep) * viewport.stepWidth(in: Double(contentWidth)))),
            height: CGFloat(viewport.semitoneHeight))
    }

    func absoluteNoteFrame(startTick: Int, durationTicks: Int, pitch: Int) -> CGRect {
        let step = Double(startTick) / Double(MusicDefaults.ticksPerStep)
        return CGRect(
            x: CGFloat(viewport.x(forStep: step, in: Double(contentWidth))) + CodaDesignTokens.Geometry.pitchGutterWidth,
            y: CGFloat(viewport.y(forMIDI: pitch)) + rollTop,
            width: max(2, CGFloat(Double(durationTicks) / Double(MusicDefaults.ticksPerStep) * viewport.stepWidth(in: Double(contentWidth)))),
            height: CGFloat(viewport.semitoneHeight)
        )
    }

    func bassNoteFrame(_ note: BassNote) -> CGRect {
        absoluteNoteFrame(startTick: note.startTick, durationTicks: note.durationTicks, pitch: note.pitch)
    }

    func melodyNoteFrame(_ note: MelodyNote) -> CGRect {
        absoluteNoteFrame(startTick: note.effectiveStartTick, durationTicks: note.durationTicks, pitch: note.pitch)
    }

    func rollNoteHit(at point: CGPoint) -> (ChordRegion, RollNote, Bool)? {
        for region in visibleRegions.reversed() {
            for note in region.notes.reversed() {
                let frame = noteFrame(note, in: region)
                if frame.contains(point) { return (region, note, point.x >= frame.maxX - min(12, frame.width * 0.3)) }
            }
        }
        return nil
    }

    func bassNoteHit(at point: CGPoint) -> (BassNote, Bool)? {
        for note in displayedBassNotes.reversed() {
            let frame = bassNoteFrame(note)
            if frame.contains(point) { return (note, point.x >= frame.maxX - min(12, frame.width * 0.3)) }
        }
        return nil
    }

    func melodyNoteHit(at point: CGPoint) -> (MelodyNote, Bool)? {
        for note in displayedMelodyNotes.reversed() {
            let frame = melodyNoteFrame(note)
            if frame.contains(point) { return (note, point.x >= frame.maxX - min(12, frame.width * 0.3)) }
        }
        return nil
    }

    private func rollCoordinates(_ point: CGPoint) -> (step: Int, pitch: Int)? {
        guard point.x >= CodaDesignTokens.Geometry.pitchGutterWidth, point.y >= rollTop,
              point.y < rootSize.height,
              let step = viewport.step(atX: Double(point.x - CodaDesignTokens.Geometry.pitchGutterWidth), in: Double(contentWidth)),
              let rawPitch = viewport.midi(atY: Double(point.y - rollTop), in: Double(rootSize.height - rollTop)) else { return nil }
        return (step, snappedPitch(rawPitch))
    }

    private func quantizedDelta(_ x: CGFloat) -> Int {
        let ticks = Double(x) / viewport.stepWidth(in: Double(contentWidth)) * Double(MusicDefaults.ticksPerStep)
        let quantum = gridSnap ? Double(MusicDefaults.ticksPerStep) : 1
        return Int(exactly: (ticks / quantum).rounded() * quantum) ?? 0
    }

    /// Snaps a root-space X coordinate to the nearest grid tick (1/16 step when Grid Snap is on)
    /// and returns both the absolute tick and its snapped root-space X for the visual razor guide.
    func snappedRazorLocation(at point: CGPoint) -> (tick: Int, snappedPoint: CGPoint)? {
        let stepWidth = viewport.stepWidth(in: Double(contentWidth))
        guard stepWidth > 0 else { return nil }
        let localX = Double(point.x - CodaDesignTokens.Geometry.pitchGutterWidth)
        let rawSteps = (localX + viewport.horizontalOffset) / stepWidth
        let rawTicks = rawSteps * Double(MusicDefaults.ticksPerStep)
        let quantum = gridSnap ? Double(MusicDefaults.ticksPerStep) : 1.0
        let snappedTicks = max(0, Int((rawTicks / quantum).rounded() * quantum))
        let snappedSteps = Double(snappedTicks) / Double(MusicDefaults.ticksPerStep)
        let snappedX = CGFloat(viewport.x(forStep: snappedSteps, in: Double(contentWidth))) + CodaDesignTokens.Geometry.pitchGutterWidth
        return (snappedTicks, CGPoint(x: snappedX, y: point.y))
    }

    /// Trims or removes any existing chord notes of the same pitch that overlap `incoming`.
    private func mergeRollNote(_ incoming: RollNote, into existing: [RollNote]) throws -> [RollNote] {
        var result: [RollNote] = []
        for note in existing {
            guard note.pitch == incoming.pitch,
                  note.startTick < incoming.endTick && note.endTick > incoming.startTick else {
                result.append(note)
                continue
            }
            if note.startTick < incoming.startTick {
                result.append(try RollNote(id: note.id, startTick: note.startTick,
                    durationTicks: incoming.startTick - note.startTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide))
            }
            if note.endTick > incoming.endTick {
                result.append(try RollNote(startTick: incoming.endTick,
                    durationTicks: note.endTick - incoming.endTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide))
            }
        }
        result.append(incoming)
        return result
    }

    /// Trims or removes any existing bass notes of the same pitch that overlap `incoming`.
    private func mergeBassNote(_ incoming: BassNote, into existing: [BassNote]) throws -> [BassNote] {
        var result: [BassNote] = []
        for note in existing {
            guard note.id != incoming.id else { continue }
            guard note.pitch == incoming.pitch,
                  note.startTick < incoming.endTick && note.endTick > incoming.startTick else {
                result.append(note)
                continue
            }
            if note.startTick < incoming.startTick {
                result.append(try BassNote(id: note.id, startTick: note.startTick,
                    durationTicks: incoming.startTick - note.startTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide,
                    provenance: note.provenance, userEdited: true))
            }
            if note.endTick > incoming.endTick {
                result.append(try BassNote(startTick: incoming.endTick,
                    durationTicks: note.endTick - incoming.endTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide,
                    provenance: note.provenance, userEdited: true))
            }
        }
        result.append(incoming)
        return result
    }

    /// Trims or removes any existing melody notes of the same pitch that overlap `incoming`.
    private func mergeMelodyNote(_ incoming: MelodyNote, into existing: [MelodyNote]) throws -> [MelodyNote] {
        var result: [MelodyNote] = []
        for note in existing {
            guard note.id != incoming.id else { continue }
            guard note.pitch == incoming.pitch,
                  note.startTick < incoming.endTick && note.endTick > incoming.startTick else {
                result.append(note)
                continue
            }
            if note.startTick < incoming.startTick {
                result.append(try MelodyNote(id: note.id, startTick: note.startTick,
                    durationTicks: incoming.startTick - note.startTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide,
                    nudgeTicks: note.nudgeTicks))
            }
            if note.endTick > incoming.endTick {
                result.append(try MelodyNote(startTick: incoming.endTick,
                    durationTicks: note.endTick - incoming.endTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide,
                    nudgeTicks: 0))
            }
        }
        result.append(incoming)
        return result
    }

    func beginRollGesture(at point: CGPoint) {
        guard EditorInputRouter.accepts(.add, from: .pencil), let coordinates = rollCoordinates(point), let session else { return }
        switch activeLayer {
        case .chords:
            beginChordRollGesture(at: point, coordinates: coordinates, session: session)
        case .bass:
            beginBassRollGesture(at: point, coordinates: coordinates, session: session)
        case .melody:
            beginMelodyRollGesture(at: point, coordinates: coordinates, session: session)
        }
    }

    private func beginChordRollGesture(at point: CGPoint, coordinates: (step: Int, pitch: Int), session: MusicSession) {
        let hit = rollNoteHit(at: point)
        let operation: PianoRollDraft.Operation
        var preview = regions
        switch rollTool {
        case .razor:
            operation = .razor
            razorPoint = point
        case .selection:
            if let (region, note, _) = hit {
                let reference = RollNoteReference(regionID: region.id, noteID: note.id)
                if !selectedNotes.contains(reference) { selectedNotes = [reference] }
                operation = .transform(selectedNotes, resize: false)
            } else {
                selectedNotes.removeAll(); rollMarquee = CGRect(origin: point, size: .zero)
                operation = .marquee
            }
        case .drawErase:
            if let (region, note, edge) = hit {
                let reference = RollNoteReference(regionID: region.id, noteID: note.id)
                if !selectedNotes.contains(reference) { selectedNotes = [reference] }
                operation = .transform(selectedNotes, resize: edge)
            } else {
                do {
                    let region: ChordRegion
                    if let existing = regions.first(where: { $0.start <= coordinates.step && $0.end > coordinates.step }) {
                        region = existing
                    } else {
                        let barStart = coordinates.step / MusicDefaults.stepsPerBar * MusicDefaults.stepsPerBar
                        let previousEnd = regions.filter { $0.end <= coordinates.step }.map(\.end).max() ?? barStart
                        let nextStart = regions.filter { $0.start > coordinates.step }.map(\.start).min() ?? barStart + MusicDefaults.stepsPerBar
                        let start = max(barStart, previousEnd)
                        let end = min(barStart + MusicDefaults.stepsPerBar, nextStart)
                        let chord = try regions.last(where: { $0.end <= start })?.chord ?? Chord(root: coordinates.pitch % 12, qualityID: "major")
                        let seed = try RollNote(startTick: (coordinates.step - start) * MusicDefaults.ticksPerStep,
                            durationTicks: MusicDefaults.ticksPerStep, pitch: coordinates.pitch)
                        region = try ChordRegion(id: UUID().uuidString, chord: chord, start: start,
                            length: end - start, pitches: [], notes: [seed], detectionUncertain: true)
                        preview.append(region)
                        operation = .draw(regionID: region.id, noteID: seed.id)
                        selectedNotes = [RollNoteReference(regionID: region.id, noteID: seed.id)]
                        rollDraft = PianoRollDraft(origin: point, original: regions, operation: operation, preview: preview, lastPoint: point)
                        auditionLayerPitch(coordinates.pitch, layer: .chords)
                        scheduleRollHold(at: point, hit: nil, step: coordinates.step)
                        return
                    }
                    let note = try RollNote(startTick: (coordinates.step - region.start) * MusicDefaults.ticksPerStep,
                        durationTicks: MusicDefaults.ticksPerStep, pitch: coordinates.pitch)
                    let merged = try mergeRollNote(note, into: region.notes)
                    let updated = try ChordRollEditor.replacing(region, notes: merged, vocabulary: session.vocabulary, detect: false)
                    preview = preview.map { $0.id == region.id ? updated : $0 }
                    selectedNotes = [RollNoteReference(regionID: region.id, noteID: note.id)]
                    operation = .draw(regionID: region.id, noteID: note.id)
                    auditionLayerPitch(coordinates.pitch, layer: .chords)
                } catch { inlineError = String(describing: error); return }
            }
        }
        rollDraft = PianoRollDraft(origin: point, original: regions, operation: operation, preview: preview, lastPoint: point)
        scheduleRollHold(at: point, hit: hit, step: coordinates.step)
    }

    private func beginBassRollGesture(at point: CGPoint, coordinates: (step: Int, pitch: Int), session: MusicSession) {
        let hit = bassNoteHit(at: point)
        let operation: BassRollDraft.Operation
        var preview = bassNotes
        switch rollTool {
        case .razor:
            operation = .razor
            razorPoint = point
        case .selection:
            if let (note, _) = hit {
                if !selectedLayerNoteIDs.contains(note.id) { selectedLayerNoteIDs = [note.id] }
                operation = .transform(selectedLayerNoteIDs, resize: false)
            } else {
                selectedLayerNoteIDs.removeAll()
                rollMarquee = CGRect(origin: point, size: .zero)
                operation = .marquee
            }
        case .drawErase:
            if let (note, edge) = hit {
                if !selectedLayerNoteIDs.contains(note.id) { selectedLayerNoteIDs = [note.id] }
                operation = .transform(selectedLayerNoteIDs, resize: edge)
            } else {
                do {
                    let startTick = coordinates.step * MusicDefaults.ticksPerStep
                    let provenance = BassFollower.evaluateProvenance(pitch: coordinates.pitch, atTick: startTick,
                        in: regions, vocabulary: session.vocabulary)
                    let note = try BassNote(startTick: startTick, durationTicks: MusicDefaults.ticksPerStep,
                        pitch: coordinates.pitch, provenance: provenance, userEdited: true)
                    preview = try mergeBassNote(note, into: preview)
                    selectedLayerNoteIDs = [note.id]
                    operation = .draw(noteID: note.id)
                    auditionLayerPitch(coordinates.pitch, layer: .bass)
                } catch { inlineError = String(describing: error); return }
            }
        }
        bassRollDraft = BassRollDraft(origin: point, original: bassNotes, operation: operation, preview: preview, lastPoint: point)
        scheduleLayerRollHold(at: point, hitNoteID: hit?.0.id, step: coordinates.step)
    }

    private func beginMelodyRollGesture(at point: CGPoint, coordinates: (step: Int, pitch: Int), session: MusicSession) {
        let hit = melodyNoteHit(at: point)
        let operation: MelodyRollDraft.Operation
        var preview = melodyNotes
        switch rollTool {
        case .razor:
            operation = .razor
            razorPoint = point
        case .selection:
            if let (note, _) = hit {
                if !selectedLayerNoteIDs.contains(note.id) { selectedLayerNoteIDs = [note.id] }
                operation = .transform(selectedLayerNoteIDs, resize: false)
            } else {
                selectedLayerNoteIDs.removeAll()
                rollMarquee = CGRect(origin: point, size: .zero)
                operation = .marquee
            }
        case .drawErase:
            if let (note, edge) = hit {
                if !selectedLayerNoteIDs.contains(note.id) { selectedLayerNoteIDs = [note.id] }
                operation = .transform(selectedLayerNoteIDs, resize: edge)
            } else {
                do {
                    let startTick = coordinates.step * MusicDefaults.ticksPerStep
                    let note = try MelodyNote(startTick: startTick, durationTicks: MusicDefaults.ticksPerStep, pitch: coordinates.pitch)
                    preview = try mergeMelodyNote(note, into: preview)
                    selectedLayerNoteIDs = [note.id]
                    operation = .draw(noteID: note.id)
                    auditionLayerPitch(coordinates.pitch, layer: .melody)
                } catch { inlineError = String(describing: error); return }
            }
        }
        melodyRollDraft = MelodyRollDraft(origin: point, original: melodyNotes, operation: operation, preview: preview, lastPoint: point)
        scheduleLayerRollHold(at: point, hitNoteID: hit?.0.id, step: coordinates.step)
    }

    private func scheduleRollHold(at point: CGPoint, hit: (ChordRegion, RollNote, Bool)?, step: Int) {
        rollHoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.popup == nil, self.rollDraft != nil else { return }
            self.rollDraft = nil; self.rollMarquee = nil; self.razorPoint = nil
            if let (region, note, _) = hit {
                let reference = RollNoteReference(regionID: region.id, noteID: note.id)
                if !self.selectedNotes.contains(reference) { self.selectedNotes = [reference] }
                self.holdMenu = HoldMenuState(regionID: nil, origin: point, selectedIndex: nil, noteReferences: self.selectedNotes)
            } else {
                self.holdMenu = HoldMenuState(regionID: nil, origin: point, selectedIndex: nil, emptyStep: step)
            }
        }
        rollHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CodaDesignTokens.Input.holdDuration, execute: work)
    }

    private func scheduleLayerRollHold(at point: CGPoint, hitNoteID: String?, step: Int) {
        rollHoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.popup == nil, (self.bassRollDraft != nil || self.melodyRollDraft != nil) else { return }
            self.bassRollDraft = nil; self.melodyRollDraft = nil; self.rollMarquee = nil; self.razorPoint = nil
            if let hitNoteID {
                if !self.selectedLayerNoteIDs.contains(hitNoteID) { self.selectedLayerNoteIDs = [hitNoteID] }
                self.holdMenu = HoldMenuState(regionID: nil, origin: point, selectedIndex: nil, layerNoteIDs: self.selectedLayerNoteIDs)
            } else {
                self.holdMenu = HoldMenuState(regionID: nil, origin: point, selectedIndex: nil, emptyStep: step)
            }
        }
        rollHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CodaDesignTokens.Input.holdDuration, execute: work)
    }

    func moveRollGesture(to point: CGPoint) {
        if let _ = bassRollDraft { moveBassRollGesture(to: point); return }
        if let _ = melodyRollDraft { moveMelodyRollGesture(to: point); return }
        guard var draft = rollDraft, let session else { return }
        if hypot(point.x - draft.origin.x, point.y - draft.origin.y) >= CodaDesignTokens.Input.holdMoveTolerance {
            rollHoldWork?.cancel(); rollHoldWork = nil
        }
        do {
            switch draft.operation {
            case .draw(let regionID, let noteID):
                guard let region = draft.preview.first(where: { $0.id == regionID }), let note = region.notes.first(where: { $0.id == noteID }) else { return }
                let tick = min(region.length * MusicDefaults.ticksPerStep,
                    note.startTick + max(MusicDefaults.ticksPerStep, quantizedDelta(point.x - draft.origin.x) + MusicDefaults.ticksPerStep))
                let updated = try RollNote(id: note.id, startTick: note.startTick, durationTicks: tick - note.startTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide)
                let others = region.notes.filter { $0.id != noteID }
                let merged = try mergeRollNote(updated, into: others)
                let next = try ChordRollEditor.replacing(region, notes: merged, vocabulary: session.vocabulary, detect: false)
                draft.preview = draft.preview.map { $0.id == regionID ? next : $0 }
            case .transform(let selection, let resizing):
                let selected = draft.original.flatMap { region in region.notes.filter { selection.contains(RollNoteReference(regionID: region.id, noteID: $0.id)) }.map { (region, $0) } }
                guard !selected.isEmpty else { return }
                var delta = quantizedDelta(point.x - draft.origin.x)
                var pitchDelta = Int((Double(draft.origin.y - point.y) / viewport.semitoneHeight).rounded())
                if resizing {
                    delta = min(selected.map { $0.0.length * MusicDefaults.ticksPerStep - $0.1.endTick }.min() ?? 0,
                        max(selected.map { 1 - $0.1.durationTicks }.max() ?? 0, delta))
                    pitchDelta = 0
                } else {
                    delta = min(selected.map { $0.0.length * MusicDefaults.ticksPerStep - $0.1.endTick }.min() ?? 0,
                        max(-(selected.map { $0.1.startTick }.min() ?? 0), delta))
                    pitchDelta = min(127 - (selected.map { $0.1.pitch }.max() ?? 127), max(-(selected.map { $0.1.pitch }.min() ?? 0), pitchDelta))
                }
                draft.preview = try draft.original.map { region in
                    let notes = try region.notes.map { note in
                        guard selection.contains(RollNoteReference(regionID: region.id, noteID: note.id)) else { return note }
                        return try RollNote(id: note.id, startTick: note.startTick + (resizing ? 0 : delta),
                            durationTicks: note.durationTicks + (resizing ? delta : 0), pitch: snappedPitch(note.pitch + pitchDelta),
                            velocity: note.velocity, slide: note.slide)
                    }
                    return try ChordRollEditor.replacing(region, notes: notes, vocabulary: session.vocabulary, detect: false)
                }
            case .marquee:
                let rect = CGRect(x: min(draft.origin.x, point.x), y: min(draft.origin.y, point.y),
                    width: abs(point.x - draft.origin.x), height: abs(point.y - draft.origin.y))
                rollMarquee = rect
                selectedNotes = Set(draft.original.flatMap { region in region.notes.filter { noteFrame($0, in: region).intersects(rect) }.map { RollNoteReference(regionID: region.id, noteID: $0.id) } })
            case .razor:
                guard let snapped = snappedRazorLocation(at: point) else { break }
                razorPoint = snapped.snappedPoint
                let absCutTick = snapped.tick
                let minY = min(point.y, draft.lastPoint.y)
                let maxY = max(point.y, draft.lastPoint.y)
                for region in draft.original {
                    let regionStartTick = region.start * MusicDefaults.ticksPerStep
                    let localCut = absCutTick - regionStartTick
                    for note in region.notes {
                        let frame = noteFrame(note, in: region)
                        let overlapsY = frame.maxY >= minY && frame.minY <= maxY
                        guard overlapsY, localCut > note.startTick, localCut < note.endTick else { continue }
                        draft.cuts[region.id, default: [:]][note.id] = localCut
                    }
                }
                draft.preview = try draft.original.flatMap { region in
                    try ChordRollEditor.slice(region, cuts: draft.cuts[region.id] ?? [:], vocabulary: session.vocabulary)
                }
            }
            draft.lastPoint = point
            rollDraft = draft
        } catch { inlineError = String(describing: error) }
    }

    private func moveBassRollGesture(to point: CGPoint) {
        guard var draft = bassRollDraft, let session else { return }
        if hypot(point.x - draft.origin.x, point.y - draft.origin.y) >= CodaDesignTokens.Input.holdMoveTolerance {
            rollHoldWork?.cancel(); rollHoldWork = nil
        }
        let maxTick = totalSteps * MusicDefaults.ticksPerStep
        do {
            switch draft.operation {
            case .draw(let noteID):
                guard let note = draft.preview.first(where: { $0.id == noteID }) else { return }
                let duration = max(MusicDefaults.ticksPerStep, quantizedDelta(point.x - draft.origin.x) + MusicDefaults.ticksPerStep)
                let clampedEnd = min(maxTick, note.startTick + duration)
                let updated = try BassNote(id: note.id, startTick: note.startTick, durationTicks: max(1, clampedEnd - note.startTick),
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide, provenance: note.provenance, userEdited: true)
                draft.preview = try mergeBassNote(updated, into: draft.original)
            case .transform(let selection, let resizing):
                let selected = draft.original.filter { selection.contains($0.id) }
                guard !selected.isEmpty else { return }
                var delta = quantizedDelta(point.x - draft.origin.x)
                var pitchDelta = Int((Double(draft.origin.y - point.y) / viewport.semitoneHeight).rounded())
                if resizing {
                    delta = min(selected.map { maxTick - $0.endTick }.min() ?? 0,
                        max(selected.map { 1 - $0.durationTicks }.max() ?? 0, delta))
                    pitchDelta = 0
                } else {
                    delta = min(selected.map { maxTick - $0.endTick }.min() ?? 0,
                        max(-(selected.map(\.startTick).min() ?? 0), delta))
                    pitchDelta = min(127 - (selected.map(\.pitch).max() ?? 127), max(-(selected.map(\.pitch).min() ?? 0), pitchDelta))
                }
                var updated = draft.original.filter { !selection.contains($0.id) }
                for note in selected {
                    let nextStart = note.startTick + (resizing ? 0 : delta)
                    let nextDuration = note.durationTicks + (resizing ? delta : 0)
                    let nextPitch = snappedPitch(note.pitch + pitchDelta)
                    let provenance = BassFollower.evaluateProvenance(pitch: nextPitch, atTick: nextStart,
                        in: regions, vocabulary: session.vocabulary)
                    let moved = try BassNote(id: note.id, startTick: nextStart, durationTicks: nextDuration,
                        pitch: nextPitch, velocity: note.velocity, slide: note.slide, provenance: provenance, userEdited: true)
                    updated = try mergeBassNote(moved, into: updated)
                }
                draft.preview = updated
            case .marquee:
                let rect = CGRect(x: min(draft.origin.x, point.x), y: min(draft.origin.y, point.y),
                    width: abs(point.x - draft.origin.x), height: abs(point.y - draft.origin.y))
                rollMarquee = rect
                selectedLayerNoteIDs = Set(draft.original.filter { bassNoteFrame($0).intersects(rect) }.map(\.id))
            case .razor:
                guard let snapped = snappedRazorLocation(at: point) else { break }
                razorPoint = snapped.snappedPoint
                let cut = snapped.tick
                let minY = min(point.y, draft.lastPoint.y)
                let maxY = max(point.y, draft.lastPoint.y)
                for note in draft.original {
                    let frame = bassNoteFrame(note)
                    let overlapsY = frame.maxY >= minY && frame.minY <= maxY
                    guard overlapsY, cut > note.startTick, cut < note.endTick else { continue }
                    draft.cuts[note.id] = cut
                }
                var track = try BassTrack(notes: draft.original)
                for (id, cut) in draft.cuts {
                    track = try track.slicing(id: id, atTick: cut)
                }
                draft.preview = track.notes
            }
            draft.lastPoint = point
            bassRollDraft = draft
        } catch { inlineError = String(describing: error) }
    }

    private func moveMelodyRollGesture(to point: CGPoint) {
        guard var draft = melodyRollDraft else { return }
        if hypot(point.x - draft.origin.x, point.y - draft.origin.y) >= CodaDesignTokens.Input.holdMoveTolerance {
            rollHoldWork?.cancel(); rollHoldWork = nil
        }
        let maxTick = totalSteps * MusicDefaults.ticksPerStep
        do {
            switch draft.operation {
            case .draw(let noteID):
                guard let note = draft.preview.first(where: { $0.id == noteID }) else { return }
                let duration = max(MusicDefaults.ticksPerStep, quantizedDelta(point.x - draft.origin.x) + MusicDefaults.ticksPerStep)
                let clampedEnd = min(maxTick, note.startTick + duration)
                let updated = try MelodyNote(id: note.id, startTick: note.startTick, durationTicks: max(1, clampedEnd - note.startTick),
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide, nudgeTicks: note.nudgeTicks)
                draft.preview = try mergeMelodyNote(updated, into: draft.original)
            case .transform(let selection, let resizing):
                let selected = draft.original.filter { selection.contains($0.id) }
                guard !selected.isEmpty else { return }
                var delta = quantizedDelta(point.x - draft.origin.x)
                var pitchDelta = Int((Double(draft.origin.y - point.y) / viewport.semitoneHeight).rounded())
                if resizing {
                    delta = min(selected.map { maxTick - $0.endTick }.min() ?? 0,
                        max(selected.map { 1 - $0.durationTicks }.max() ?? 0, delta))
                    pitchDelta = 0
                } else {
                    delta = min(selected.map { maxTick - $0.endTick }.min() ?? 0,
                        max(-(selected.map(\.startTick).min() ?? 0), delta))
                    pitchDelta = min(127 - (selected.map(\.pitch).max() ?? 127), max(-(selected.map(\.pitch).min() ?? 0), pitchDelta))
                }
                var updated = draft.original.filter { !selection.contains($0.id) }
                for note in selected {
                    let moved = try MelodyNote(id: note.id, startTick: note.startTick + (resizing ? 0 : delta),
                        durationTicks: note.durationTicks + (resizing ? delta : 0),
                        pitch: snappedPitch(note.pitch + pitchDelta), velocity: note.velocity, slide: note.slide,
                        nudgeTicks: note.nudgeTicks)
                    updated = try mergeMelodyNote(moved, into: updated)
                }
                draft.preview = updated
            case .marquee:
                let rect = CGRect(x: min(draft.origin.x, point.x), y: min(draft.origin.y, point.y),
                    width: abs(point.x - draft.origin.x), height: abs(point.y - draft.origin.y))
                rollMarquee = rect
                selectedLayerNoteIDs = Set(draft.original.filter { melodyNoteFrame($0).intersects(rect) }.map(\.id))
            case .razor:
                guard let snapped = snappedRazorLocation(at: point) else { break }
                razorPoint = snapped.snappedPoint
                let cut = snapped.tick
                let minY = min(point.y, draft.lastPoint.y)
                let maxY = max(point.y, draft.lastPoint.y)
                for note in draft.original {
                    let frame = melodyNoteFrame(note)
                    let overlapsY = frame.maxY >= minY && frame.minY <= maxY
                    guard overlapsY, cut > note.startTick, cut < note.endTick else { continue }
                    draft.cuts[note.id] = cut
                }
                var track = try MelodyTrack(notes: draft.original)
                for (id, cut) in draft.cuts {
                    track = try track.slicing(id: id, atTick: cut)
                }
                draft.preview = track.notes
            }
            draft.lastPoint = point
            melodyRollDraft = draft
        } catch { inlineError = String(describing: error) }
    }

    func finishRollGesture(at point: CGPoint, moved: Bool) {
        guard let session else { cancelRollGesture(); return }
        rollHoldWork?.cancel(); rollHoldWork = nil
        if moved || rollTool == .razor { moveRollGesture(to: point) }

        if let draft = bassRollDraft {
            var next = draft.preview
            if case .transform = draft.operation, !moved, rollTool == .drawErase,
               let (note, _) = bassNoteHit(at: draft.origin) {
                next = draft.original.filter { $0.id != note.id }
                selectedLayerNoteIDs.remove(note.id)
            }
            if case .marquee = draft.operation { cancelRollGesture(); return }
            cancelRollGesture()
            commitBassNotes(next)
            return
        }

        if let draft = melodyRollDraft {
            var next = draft.preview
            if case .transform = draft.operation, !moved, rollTool == .drawErase,
               let (note, _) = melodyNoteHit(at: draft.origin) {
                next = draft.original.filter { $0.id != note.id }
                selectedLayerNoteIDs.remove(note.id)
            }
            if case .marquee = draft.operation { cancelRollGesture(); return }
            cancelRollGesture()
            commitMelodyNotes(next)
            return
        }

        guard let draft = rollDraft else { return }
        var next = draft.preview
        if case .transform(_, _) = draft.operation, !moved, rollTool == .drawErase,
           let (region, note, _) = rollNoteHit(at: draft.origin) {
            next = draft.original.compactMap { value in
                guard value.id == region.id else { return value }
                let remaining = value.notes.filter { $0.id != note.id }
                guard !remaining.isEmpty else { return nil }
                return try? ChordRollEditor.replacing(value, notes: remaining, vocabulary: session.vocabulary)
            }
            selectedNotes.remove(RollNoteReference(regionID: region.id, noteID: note.id))
        }
        if case .marquee = draft.operation { cancelRollGesture(); return }
        cancelRollGesture()
        commitRollRegions(next, previous: draft.original)
    }

    func cancelRollGesture() {
        rollHoldWork?.cancel(); rollHoldWork = nil
        rollDraft = nil; bassRollDraft = nil; melodyRollDraft = nil
        rollMarquee = nil; razorPoint = nil
    }

    func commitBassNotes(_ notes: [BassNote]) {
        guard let session else { return }
        do {
            let maxStep = notes.map { ($0.endTick - 1) / MusicDefaults.ticksPerStep + 1 }.max() ?? 0
            if maxStep > totalSteps {
                try session.extendArrangement(through: maxStep)
                viewport.extend(through: totalSteps)
            }
            let track = try BassTrack(notes: notes)
            try session.setBassTrack(track)
            selectedLayerNoteIDs = selectedLayerNoteIDs.filter { id in bassNotes.contains { $0.id == id } }
            scheduleAutosave()
            inlineError = nil
        } catch { inlineError = String(describing: error) }
    }

    func commitMelodyNotes(_ notes: [MelodyNote]) {
        guard let session else { return }
        do {
            let maxStep = notes.map { ($0.endTick - 1) / MusicDefaults.ticksPerStep + 1 }.max() ?? 0
            if maxStep > totalSteps {
                try session.extendArrangement(through: maxStep)
                viewport.extend(through: totalSteps)
            }
            let track = try MelodyTrack(notes: notes)
            try session.setMelodyTrack(track)
            selectedLayerNoteIDs = selectedLayerNoteIDs.filter { id in melodyNotes.contains { $0.id == id } }
            scheduleAutosave()
            inlineError = nil
        } catch { inlineError = String(describing: error) }
    }

    func commitRollRegions(_ next: [ChordRegion], previous: [ChordRegion]? = nil) {
        guard let session else { return }
        let original = previous ?? regions
        do {
            var edits: [ProgressionEdit] = original.filter { old in !next.contains(where: { $0.id == old.id }) }.map { .delete(id: $0.id) }
            for region in next {
                let old = original.first { $0.id == region.id }
                guard old != region else { continue }
                let detected: ChordRegion
                if let old, !old.detectionUncertain,
                   Set(old.notes.map { $0.pitch % 12 }) == Set(region.notes.map { $0.pitch % 12 }) {
                    // Octave moves and rhythm-only edits retain the identity.
                    detected = try ChordRegion(id: region.id, chord: old.chord, start: region.start,
                        length: region.length, pitches: [], notes: region.notes)
                } else {
                    detected = try ChordRollEditor.replacing(region, notes: region.notes, vocabulary: session.vocabulary)
                }
                edits.append(old == nil ? .add(detected) : .replace(detected))
                sidekick.dismissGhosts(overlapping: detected.start, lengthSteps: detected.length)
            }
            try session.edit(edits)
            viewport.extend(through: totalSteps)
            selectedNotes = selectedNotes.filter { reference in regions.contains { $0.id == reference.regionID && $0.notes.contains { $0.id == reference.noteID } } }
            scheduleAutosave()
            inlineError = nil
        } catch { inlineError = String(describing: error) }
    }

    func copyRollSelection() {
        switch activeLayer {
        case .chords:
            let notes = regions.flatMap { region in region.notes.filter { selectedNotes.contains(RollNoteReference(regionID: region.id, noteID: $0.id)) }.map { (region.start * MusicDefaults.ticksPerStep + $0.startTick, $0) } }
            guard let first = notes.map({ $0.0 }).min() else { return }
            rollClipboard = notes.map { CopiedRollNote(offsetTicks: $0.0 - first, durationTicks: $0.1.durationTicks, pitch: $0.1.pitch, velocity: $0.1.velocity, slide: $0.1.slide) }
        case .bass:
            let selected = bassNotes.filter { selectedLayerNoteIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            bassClipboard = selected
        case .melody:
            let selected = melodyNotes.filter { selectedLayerNoteIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            melodyClipboard = selected
        }
    }

    /// Same-layer clipboard, absolute pitches, playhead placement.
    func pasteRollNotes(at step: Int) {
        guard let session, step >= 0, step <= Int.max / MusicDefaults.ticksPerStep else { return }
        switch activeLayer {
        case .bass:
            guard !bassClipboard.isEmpty, let earliest = bassClipboard.map(\.startTick).min() else { return }
            do {
                let anchorTick = step * MusicDefaults.ticksPerStep
                var updated = bassNotes
                var newIDs = Set<String>()
                var maxEndStep = totalSteps
                for note in bassClipboard {
                    let (target, overflow) = anchorTick.addingReportingOverflow(note.startTick - earliest)
                    guard !overflow, target >= 0 else { throw MusicError.timingOverflow }
                    let pasted = try BassNote(id: UUID().uuidString, startTick: target, durationTicks: note.durationTicks,
                        pitch: note.pitch, velocity: note.velocity, slide: note.slide,
                        provenance: BassFollower.evaluateProvenance(pitch: note.pitch, atTick: target, in: regions, vocabulary: session.vocabulary),
                        userEdited: true)
                    updated = try mergeBassNote(pasted, into: updated)
                    newIDs.insert(pasted.id)
                    maxEndStep = max(maxEndStep, (pasted.endTick - 1) / MusicDefaults.ticksPerStep + 1)
                }
                if maxEndStep > totalSteps {
                    try session.extendArrangement(through: maxEndStep)
                    viewport.extend(through: totalSteps)
                }
                selectedLayerNoteIDs = newIDs
                commitBassNotes(updated)
            } catch { inlineError = String(describing: error) }

        case .melody:
            guard !melodyClipboard.isEmpty, let earliest = melodyClipboard.map(\.startTick).min() else { return }
            do {
                let anchorTick = step * MusicDefaults.ticksPerStep
                var updated = melodyNotes
                var newIDs = Set<String>()
                var maxEndStep = totalSteps
                for note in melodyClipboard {
                    let (target, overflow) = anchorTick.addingReportingOverflow(note.startTick - earliest)
                    guard !overflow, target >= 0 else { throw MusicError.timingOverflow }
                    let pasted = try MelodyNote(id: UUID().uuidString, startTick: target, durationTicks: note.durationTicks,
                        pitch: note.pitch, velocity: note.velocity, slide: note.slide, nudgeTicks: note.nudgeTicks)
                    updated = try mergeMelodyNote(pasted, into: updated)
                    newIDs.insert(pasted.id)
                    maxEndStep = max(maxEndStep, (pasted.endTick - 1) / MusicDefaults.ticksPerStep + 1)
                }
                if maxEndStep > totalSteps {
                    try session.extendArrangement(through: maxEndStep)
                    viewport.extend(through: totalSteps)
                }
                selectedLayerNoteIDs = newIDs
                commitMelodyNotes(updated)
            } catch { inlineError = String(describing: error) }

        case .chords:
            guard !rollClipboard.isEmpty else { return }
            do {
                var maxEndStep = totalSteps
                for copied in rollClipboard {
                    let (absolute, overflow) = (step * MusicDefaults.ticksPerStep).addingReportingOverflow(copied.offsetTicks)
                    let (endTick, endOverflow) = absolute.addingReportingOverflow(copied.durationTicks)
                    guard !overflow, !endOverflow else { throw MusicError.timingOverflow }
                    maxEndStep = max(maxEndStep, (endTick - 1) / MusicDefaults.ticksPerStep + 1)
                }
                if maxEndStep > totalSteps {
                    try session.extendArrangement(through: maxEndStep)
                    viewport.extend(through: totalSteps)
                }
                var next = regions
                var selection = Set<RollNoteReference>()
                for copied in rollClipboard {
                    let (absolute, overflow) = (step * MusicDefaults.ticksPerStep).addingReportingOverflow(copied.offsetTicks)
                    let (endTick, endOverflow) = absolute.addingReportingOverflow(copied.durationTicks)
                    guard !overflow, !endOverflow else { throw MusicError.timingOverflow }
                    let startStep = absolute / MusicDefaults.ticksPerStep
                    let endStep = (endTick - 1) / MusicDefaults.ticksPerStep + 1
                    var cursor = startStep
                    // Keep pasted note timing across existing harmonic boundaries and trim same-pitch overlaps.
                    while cursor < endStep {
                        if let i = next.firstIndex(where: { $0.start <= cursor && $0.end > cursor }) {
                            let region = next[i]
                            let lo = max(absolute, region.start * MusicDefaults.ticksPerStep)
                            let hi = min(endTick, region.end * MusicDefaults.ticksPerStep)
                            let note = try RollNote(startTick: lo - region.start * MusicDefaults.ticksPerStep, durationTicks: hi - lo,
                                pitch: copied.pitch, velocity: copied.velocity, slide: copied.slide)
                            let merged = try mergeRollNote(note, into: region.notes)
                            next[i] = try ChordRollEditor.replacing(region, notes: merged, vocabulary: session.vocabulary, detect: false)
                            selection.insert(RollNoteReference(regionID: region.id, noteID: note.id)); cursor = region.end
                        } else {
                            let nextStart = next.filter { $0.start > cursor }.map(\.start).min() ?? endStep
                            let end = min(endStep, nextStart)
                            let note = try RollNote(startTick: max(0, absolute - cursor * MusicDefaults.ticksPerStep),
                                durationTicks: min(endTick, end * MusicDefaults.ticksPerStep) - max(absolute, cursor * MusicDefaults.ticksPerStep),
                                pitch: copied.pitch, velocity: copied.velocity, slide: copied.slide)
                            let chord = try next.last(where: { $0.end <= cursor })?.chord ?? Chord(root: copied.pitch % 12, qualityID: "major")
                            let region = try ChordRegion(id: UUID().uuidString, chord: chord, start: cursor, length: end - cursor, pitches: [], notes: [note])
                            next.append(region); selection.insert(RollNoteReference(regionID: region.id, noteID: note.id)); cursor = end
                        }
                    }
                }
                selectedNotes = selection
                commitRollRegions(next)
            } catch { inlineError = String(describing: error) }
        }
    }

    var hasActiveLayerSelection: Bool {
        activeLayer == .chords ? !selectedNotes.isEmpty : !selectedLayerNoteIDs.isEmpty
    }

    var hasActiveLayerClipboard: Bool {
        switch activeLayer {
        case .chords: !rollClipboard.isEmpty
        case .bass: !bassClipboard.isEmpty
        case .melody: !melodyClipboard.isEmpty
        }
    }

    var holdCommands: [ObjectHoldCommand] {
        guard let menu = holdMenu else { return [] }
        if menu.ghostID != nil {
            return [
                .init(title: "Audition", symbol: "speaker.wave.2.fill"),
                .init(title: "Accept", symbol: "checkmark.circle.fill"),
                .init(title: "Accept All", symbol: "checkmark.circle.badge.plus"),
                .init(title: "Dismiss All", symbol: "xmark.circle", destructive: true)
            ]
        }
        if menu.regionID != nil {
            return [.init(title: "Copy", symbol: "doc.on.doc"), .init(title: "Duplicate", symbol: "plus.square.on.square"),
                .init(title: "Delete", symbol: "trash", destructive: true), .init(title: "Split here", symbol: "scissors")]
        }
        if menu.emptyStep != nil {
            return [.init(title: "Paste here", symbol: "doc.on.clipboard", enabled: hasActiveLayerClipboard),
                    .init(title: "Select bar", symbol: "selection.pin.in.out")]
        }
        let multiCount = activeLayer == .chords ? menu.noteReferences.count : menu.layerNoteIDs.count
        var items: [ObjectHoldCommand] = [
            .init(title: "Copy", symbol: "doc.on.doc"),
            .init(title: "Duplicate", symbol: "plus.square.on.square"),
            .init(title: "Delete", symbol: "trash", destructive: true)
        ]
        if multiCount > 1 {
            items += [.init(title: "Octave up", symbol: "arrow.up"), .init(title: "Octave down", symbol: "arrow.down")]
        } else {
            items.append(.init(title: "Slide into note", symbol: "point.topleft.down.to.point.bottomright.curvepath"))
        }
        return items
    }

    func performObjectHoldCommand(_ index: Int, state: HoldMenuState) {
        guard holdCommands.indices.contains(index), holdCommands[index].enabled, let session else { return }
        if let ghostID = state.ghostID, let ghost = sidekick.activeGhosts.first(where: { $0.id == ghostID }) {
            switch index {
            case 0: auditionGhost(ghost)
            case 1: acceptGhost(ghost)
            case 2: acceptAllGhosts()
            case 3: sidekick.dismissAllGhosts()
            default: break
            }
            return
        }
        if let id = state.regionID, let region = regions.first(where: { $0.id == id }) {
            do {
                switch index {
                case 0: try copyChordFromHold(id)
                case 1:
                    try session.edit([.duplicate(id: id, newID: UUID().uuidString, start: region.end)])
                    scheduleAutosave()
                case 2:
                    try session.edit([.delete(id: id)])
                    if selectedRegionID == id { selectedRegionID = nil }
                    scheduleAutosave()
                case 3:
                    guard let step = viewport.step(atX: Double(state.origin.x - CodaDesignTokens.Geometry.pitchGutterWidth), in: Double(contentWidth)), step > region.start, step < region.end else { return }
                    let tick = (step - region.start) * MusicDefaults.ticksPerStep
                    let cuts = Dictionary(uniqueKeysWithValues: region.notes.filter { $0.startTick < tick && $0.endTick > tick }.map { ($0.id, tick) })
                    let parts = try ChordRollEditor.slice(region, cuts: cuts, vocabulary: session.vocabulary)
                    commitRollRegions(regions.filter { $0.id != id } + parts)
                default: break
                }
                viewport.extend(through: totalSteps)
            } catch { inlineError = String(describing: error) }
            return
        }
        if let step = state.emptyStep {
            if index == 0 {
                pasteRollNotes(at: step)
            } else {
                let bar = step / MusicDefaults.stepsPerBar
                switch activeLayer {
                case .chords:
                    selectedNotes = Set(regions.flatMap { region in region.notes.filter {
                        let start = region.start + $0.startTick / MusicDefaults.ticksPerStep
                        return start / MusicDefaults.stepsPerBar == bar
                    }.map { RollNoteReference(regionID: region.id, noteID: $0.id) } })
                case .bass:
                    selectedLayerNoteIDs = Set(bassNotes.filter {
                        ($0.startTick / MusicDefaults.ticksPerStep) / MusicDefaults.stepsPerBar == bar
                    }.map(\.id))
                case .melody:
                    selectedLayerNoteIDs = Set(melodyNotes.filter {
                        ($0.startTick / MusicDefaults.ticksPerStep) / MusicDefaults.stepsPerBar == bar
                    }.map(\.id))
                }
                rollTool = .selection
            }
            return
        }

        if activeLayer != .chords {
            performLayerNoteHoldCommand(index, ids: state.layerNoteIDs)
            return
        }

        selectedNotes = state.noteReferences
        if index == 0 { copyRollSelection(); return }
        if index == 1 {
            copyRollSelection()
            let end = regions.flatMap { region in region.notes.filter { selectedNotes.contains(RollNoteReference(regionID: region.id, noteID: $0.id)) }.map { region.start + ($0.endTick - 1) / MusicDefaults.ticksPerStep + 1 } }.max() ?? playheadStep
            pasteRollNotes(at: end); return
        }
        do {
            let next = try regions.compactMap { region -> ChordRegion? in
                var notes: [RollNote] = []
                for note in region.notes {
                    guard selectedNotes.contains(RollNoteReference(regionID: region.id, noteID: note.id)) else { notes.append(note); continue }
                    if index == 2 { continue }
                    let pitch = note.pitch + (state.noteReferences.count > 1 ? (index == 3 ? 12 : -12) : 0)
                    notes.append(try RollNote(id: note.id, startTick: note.startTick, durationTicks: note.durationTicks,
                        pitch: pitch, velocity: note.velocity, slide: state.noteReferences.count == 1 ? !note.slide : note.slide))
                }
                guard !notes.isEmpty else { return nil }
                return try ChordRollEditor.replacing(region, notes: notes, vocabulary: session.vocabulary)
            }
            commitRollRegions(next)
        } catch { inlineError = String(describing: error) }
    }

    private func performLayerNoteHoldCommand(_ index: Int, ids: Set<String>) {
        selectedLayerNoteIDs = ids
        if index == 0 { copyRollSelection(); return }
        if index == 1 {
            copyRollSelection()
            let maxEndStep: Int
            if activeLayer == .bass {
                maxEndStep = bassNotes.filter { ids.contains($0.id) }.map { ($0.endTick - 1) / MusicDefaults.ticksPerStep + 1 }.max() ?? playheadStep
            } else {
                maxEndStep = melodyNotes.filter { ids.contains($0.id) }.map { ($0.endTick - 1) / MusicDefaults.ticksPerStep + 1 }.max() ?? playheadStep
            }
            pasteRollNotes(at: maxEndStep)
            return
        }
        do {
            if activeLayer == .bass {
                var track = try BassTrack(notes: bassNotes)
                switch index {
                case 2: track = try track.deleting(ids: ids); selectedLayerNoteIDs.subtract(ids)
                case 3:
                    if ids.count > 1 { track = try track.transposing(ids: ids, semitones: 12) }
                    else if let first = ids.first { track = try track.togglingSlide(id: first) }
                case 4: track = try track.transposing(ids: ids, semitones: -12)
                default: break
                }
                commitBassNotes(track.notes)
            } else if activeLayer == .melody {
                var track = try MelodyTrack(notes: melodyNotes)
                switch index {
                case 2: track = try track.deleting(ids: ids); selectedLayerNoteIDs.subtract(ids)
                case 3:
                    if ids.count > 1 { track = try track.transposing(ids: ids, semitones: 12) }
                    else if let first = ids.first { track = try track.togglingSlide(id: first) }
                case 4: track = try track.transposing(ids: ids, semitones: -12)
                default: break
                }
                commitMelodyNotes(track.notes)
            }
        } catch { inlineError = String(describing: error) }
    }

    func rollChordVoicing(_ region: ChordRegion, angle: Double, at point: CGPoint) {
        guard angle.isFinite, rollDraft == nil, let session else { return }
        if chordRollTarget != region.id {
            finishChordVoicingRoll()
            chordRollTarget = region.id; chordRollBase = region; chordRollAngle = angle
            chordRollAccumulator = BarrelRollAccumulator(); chordRollFraction = 0
            return
        }
        guard let previous = chordRollAngle else { chordRollAngle = angle; return }
        let degrees = Self.clockwiseBarrelDeltaDegrees(from: previous, to: angle)
        chordRollAngle = angle
        chordRollFraction += chordRollAccumulator.consume(degrees: degrees) * 360 / 24
        let detents = Int(chordRollFraction.rounded(.towardZero))
        guard detents != 0, let base = chordRollBase else { return }
        chordRollFraction -= Double(detents)
        do {
            let candidates = try session.solver.candidates(for: base.chord, vocabulary: session.vocabulary)
                .sorted { lhs, rhs in
                    let a = lhs.reduce(0, +), b = rhs.reduce(0, +)
                    return a == b ? lhs.lexicographicallyPrecedes(rhs) : a < b
                }
            guard !candidates.isEmpty else { return }
            let current = candidates.firstIndex(of: chordRollPreview?.pitches ?? base.pitches) ?? candidates.indices.min { lhs, rhs in
                abs(candidates[lhs].reduce(0, +) - base.pitches.reduce(0, +)) < abs(candidates[rhs].reduce(0, +) - base.pitches.reduce(0, +))
            } ?? 0
            let index = min(candidates.count - 1, max(0, current + detents))
            guard index != current else { return }
            let pitches = candidates[index]
            chordRollPreview = try ChordRollEditor.voicing(base, pitches: pitches)
            try session.audition(pitches: pitches)
            radialPreview = "Voicing \(index + 1) / \(candidates.count)"
            triggerVisualDetent(at: point, intensity: 0.65, isCompletion: false)
        } catch { inlineError = String(describing: error) }
    }

    func finishChordVoicingRoll(commit: Bool = true) {
        if commit, let preview = chordRollPreview, preview != chordRollBase {
            do {
                try session?.edit([.replace(preview)])
                scheduleAutosave()
            } catch { inlineError = String(describing: error) }
        }
        if chordRollTarget != nil || chordRollPreview != nil {
            if radial == nil { radialPreview = nil }
        }
        chordRollPreview = nil; chordRollBase = nil; chordRollTarget = nil; chordRollAngle = nil
        chordRollFraction = 0
    }

    /// Barrel-roll micro-timing nudge for Melody notes (SPEC §10).
    func rollMelodyNudge(_ note: MelodyNote, angle: Double, at point: CGPoint) {
        guard angle.isFinite, !hasActiveRollDraft else { return }
        if melodyNudgeTarget != note.id {
            finishMelodyNudgeRoll()
            melodyNudgeTarget = note.id; melodyNudgeBase = note; melodyNudgeAngle = angle
            melodyNudgeAccumulator = BarrelRollAccumulator(); melodyNudgeFraction = 0
            return
        }
        guard let previous = melodyNudgeAngle else { melodyNudgeAngle = angle; return }
        let degrees = Self.clockwiseBarrelDeltaDegrees(from: previous, to: angle)
        melodyNudgeAngle = angle
        melodyNudgeFraction += melodyNudgeAccumulator.consume(degrees: degrees) * 360 / 18
        let detents = Int(melodyNudgeFraction.rounded(.towardZero))
        guard detents != 0, let base = melodyNudgeBase else { return }
        melodyNudgeFraction -= Double(detents)
        let currentNudge = melodyNudgePreview?.nudgeTicks ?? base.nudgeTicks
        let nextNudge = max(-120, min(120, currentNudge + detents * 5))
        guard nextNudge != currentNudge else { return }
        do {
            melodyNudgePreview = try MelodyNote(id: base.id, startTick: base.startTick, durationTicks: base.durationTicks,
                pitch: base.pitch, velocity: base.velocity, slide: base.slide, nudgeTicks: nextNudge)
            let sign = nextNudge > 0 ? "+" : ""
            radialPreview = "Nudge \(sign)\(nextNudge)t"
            triggerVisualDetent(at: point, intensity: 0.55, isCompletion: false)
        } catch { inlineError = String(describing: error) }
    }

    func finishMelodyNudgeRoll(commit: Bool = true) {
        if commit, let preview = melodyNudgePreview, preview != melodyNudgeBase {
            let next = melodyNotes.map { $0.id == preview.id ? preview : $0 }
            commitMelodyNotes(next)
        }
        if melodyNudgeTarget != nil || melodyNudgePreview != nil {
            if radial == nil { radialPreview = nil }
        }
        melodyNudgePreview = nil; melodyNudgeBase = nil; melodyNudgeTarget = nil
        melodyNudgeAngle = nil; melodyNudgeFraction = 0
    }
}
