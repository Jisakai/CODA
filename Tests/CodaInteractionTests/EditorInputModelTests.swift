import XCTest
import CodaMusic
import CodaInteraction

final class EditorInputModelTests: XCTestCase {
    func testEveryMusicMutationIsRejectedForFingerAndAcceptedForPencil() {
        let actions: [MusicEditAction] = [
            .add, .select, .audition, .resize, .duplicate, .copy, .paste, .delete,
            .changeRoot, .changeQuality
        ]
        for action in actions {
            XCTAssertFalse(EditorInputRouter.accepts(action, from: .finger), "Finger routed \(action)")
            XCTAssertTrue(EditorInputRouter.accepts(action, from: .pencil), "Pencil blocked \(action)")
        }
    }

    func testOnlyExactFingerMultiTapCountsProduceShortcuts() {
        XCTAssertEqual(FingerShortcutRouter.action(touchCount: 2, tapCount: 2), .undo)
        XCTAssertEqual(FingerShortcutRouter.action(touchCount: 3, tapCount: 2), .redo)
        XCTAssertEqual(FingerShortcutRouter.action(touchCount: 4, tapCount: 1), .toggleChrome)
        for counts in [(2, 1), (3, 1), (4, 2), (1, 2), (5, 1)] {
            XCTAssertNil(FingerShortcutRouter.action(touchCount: counts.0, tapCount: counts.1))
        }
    }

    func testViewportSharesStepAndPitchCoordinatesAtExactEdges() {
        let width = 1310.0
        var viewport = EditorViewport()
        XCTAssertEqual(viewport.step(atX: 0, in: width), 0)
        XCTAssertNil(viewport.step(atX: width, in: width), "Right boundary is exclusive")
        for step in [0, 1, 15, 16, 63, 127] {
            let x = viewport.x(forStep: Double(step) + 0.25, in: width)
            XCTAssertEqual(viewport.step(atX: x, in: width), step)
        }
        XCTAssertEqual(viewport.midi(atY: 0, in: 400), 84)
        XCTAssertEqual(viewport.midi(atY: 21.99, in: 400), 84)
        XCTAssertEqual(viewport.midi(atY: 22, in: 400), 83)
        XCTAssertNil(viewport.midi(atY: 400, in: 400))
    }

    func testZoomKeepsAnchorAndPanClampsBothAxes() {
        let width = 1200.0
        var viewport = EditorViewport()
        let anchor = 440.0
        let before = (anchor + viewport.horizontalOffset) / viewport.stepWidth(in: width)
        viewport.zoom(to: 2, anchoredAtX: anchor, canvasWidth: width)
        let after = (anchor + viewport.horizontalOffset) / viewport.stepWidth(in: width)
        XCTAssertEqual(before, after, accuracy: 1e-9)
        viewport.pan(horizontalBy: -100_000, verticalBy: -100_000,
                     canvasWidth: width, canvasHeight: 500)
        XCTAssertEqual(viewport.horizontalOffset, viewport.maximumHorizontalOffset(width: width))
        XCTAssertEqual(viewport.verticalOffset, Double(viewport.topMIDI + 1) * viewport.semitoneHeight - 500)
        XCTAssertEqual(viewport.midi(atY: 499.99, in: 500), 0)
        viewport.pan(horizontalBy: 100_000, verticalBy: 100_000,
                     canvasWidth: width, canvasHeight: 500)
        XCTAssertEqual(viewport.horizontalOffset, 0)
        XCTAssertEqual(viewport.verticalOffset, Double(84 - 127) * viewport.semitoneHeight)
        XCTAssertEqual(viewport.midi(atY: 0, in: 500), 127)
    }

    func testChordStripHitTestingDistinguishesResizeEdgeEmptyBarsAndGutter() {
        let width = 1310.0
        let viewport = EditorViewport()
        let stepWidth = viewport.stepWidth(in: width)
        let regions: [(id: String, start: Int, end: Int)] = [("a", 0, 16), ("b", 32, 40)]

        let nearRight = ChordStripHitTester.hit(x: 56 + stepWidth * 15.5, y: 20, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions)
        XCTAssertEqual(nearRight?.target, .region(id: "a", resizeEdge: true))

        let empty = ChordStripHitTester.hit(x: 56 + stepWidth * 20, y: 50, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions)
        XCTAssertEqual(empty?.target, .emptyBar(startStep: 16))

        let occupied = ChordStripHitTester.hit(x: 56 + stepWidth * 35, y: 40, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions)
        XCTAssertEqual(occupied?.target, .region(id: "b", resizeEdge: false))

        XCTAssertNil(ChordStripHitTester.hit(x: 55, y: 40, width: 1366, height: 104,
            headerWidth: 56, viewport: viewport, regions: regions))
        XCTAssertEqual(ChordStripHitTester.hit(x: 56, y: 40, width: 1366, height: 104,
            headerWidth: 56, viewport: viewport, regions: regions)?.target,
            .region(id: "a", resizeEdge: false))
        XCTAssertNil(ChordStripHitTester.hit(x: 56 + stepWidth * 50, y: 104, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions))
    }

    func testHoldMenuUsesVisibleClampedRowsAndRejectsDividersAndOutside() {
        for origin in [CGPoint(x: 100, y: 100), CGPoint(x: 1360, y: 1020)] {
            let layout = HoldMenuLayout(origin: origin, viewport: CGSize(width: 1366, height: 1024),
                minimumY: 176, width: 224, rowHeight: 40, dividerHeight: 1)
            XCTAssertGreaterThanOrEqual(layout.frame.minY, 176)
            XCTAssertLessThanOrEqual(layout.frame.maxY, 1016)
            XCTAssertLessThanOrEqual(layout.frame.maxX, 1358)
            for index in 0..<3 {
                let y = layout.frame.minY + Double(index * 41)
                XCTAssertEqual(layout.row(at: CGPoint(x: layout.frame.midX, y: y)), index)
                XCTAssertEqual(layout.row(at: CGPoint(x: layout.frame.midX, y: y + 20)), index)
                XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.minX - 0.1, y: y + 20)))
                XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.maxX, y: y + 20)))
                if index < 2 { XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.midX, y: y + 40.5))) }
            }
            XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.midX, y: layout.frame.minY - 0.1)))
            XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.midX, y: layout.frame.maxY)))
        }
    }

    func testRadialActionsKeepSwapAndQualitySelectionSeparateAndDisableUnavailablePaste() {
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .existingChord, ring: .inner,
            slot: 0, suggestionCount: 3, hasClipboard: false), .swapRoot)
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .existingChord, ring: .outer,
            slot: 0, suggestionCount: 3, hasClipboard: false), .suggestion(0))
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .emptyBar, ring: .inner,
            slot: 0, suggestionCount: 3, hasClipboard: false), nil)
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .emptyBar, ring: .inner,
            slot: 0, suggestionCount: 3, hasClipboard: true), .paste)
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .emptyBar, ring: .inner,
            slot: 1, suggestionCount: 3, hasClipboard: false), .rest)

        var draft = RadialSwapDraft(root: 0, qualityID: "minor7")
        draft.chooseRoot(7)
        draft.chooseQuality("dominant7")
        XCTAssertEqual(draft.root, 7)
        XCTAssertEqual(draft.qualityID, "dominant7")
    }

    func testEveryProductionVocabularyQualityIsReachableOnItsFamilyRing() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: EditorInputModelTests.self))
        var visited = Set<String>()
        for family in ChordFamily.allCases {
            let ring: RadialRing = switch family {
            case .major: .major
            case .minor: .minor
            case .odd: .odd
            }
            let identifiers = vocabulary.ring(family).map(\.id)
            for index in identifiers.indices {
                XCTAssertEqual(RadialChoiceResolver.resolve(context: .existingChord, ring: ring,
                    slot: index, suggestionCount: 3, hasClipboard: false,
                    qualityIDs: identifiers), .changeQuality(identifiers[index]))
                visited.insert(identifiers[index])
            }
        }
        XCTAssertEqual(visited, Set(vocabulary.qualities.map(\.id)))
    }

    func testRadialRingBoundariesAngleSlotsAndCenterDeadZone() {
        XCTAssertNil(RadialGeometry.ring(forRadius: 40, rings: [(.inner, 64, 104)]))
        XCTAssertEqual(RadialGeometry.ring(forRadius: 64, rings: [(.inner, 64, 104)]), .inner)
        XCTAssertEqual(RadialGeometry.ring(forRadius: 104, rings: [(.inner, 64, 104)]), .inner)
        for count in [4, 7, 12, 13] {
            for slot in 0..<count {
                let angle = RadialGeometry.angle(forSlot: slot, count: count)
                XCTAssertEqual(RadialGeometry.slot(atAngle: angle, count: count), slot)
                XCTAssertEqual(RadialGeometry.slot(atAngle: angle + 1e-9, count: count), slot)
                XCTAssertEqual(RadialGeometry.slot(atAngle: angle - 1e-9, count: count),
                               (slot + count - 1) % count)
            }
        }
    }

    func testRadialPreviewDraftDoesNotEditProgressionOrHistory() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: EditorInputModelTests.self))
        let original = try Chord(root: 0, qualityID: "minor7")
        let pitches = try VoiceLeadingSolver().solve([original], vocabulary: vocabulary)[0]
        let region = try ChordRegion(id: "preview", chord: original, start: 0, length: 16, pitches: pitches)
        let progression = try Progression(regions: [region], vocabulary: vocabulary)
        let editor = ProgressionEditor(progression)
        var draft = RadialSwapDraft(root: original.root, qualityID: original.qualityID)
        draft.chooseRoot(7)
        draft.chooseQuality("dominant7")

        XCTAssertEqual(draft.root, 7)
        XCTAssertEqual(draft.qualityID, "dominant7")
        XCTAssertEqual(editor.progression, progression)
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
    }

    func testBarrelRollDeadZoneAndFivePercentDetents() {
        var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
        XCTAssertEqual(roll.consume(degrees: 7), 0)
        XCTAssertEqual(roll.consume(degrees: 4), 0)
        XCTAssertEqual(roll.consume(degrees: 5), 4.0 / 360.0, accuracy: 1e-9)
        XCTAssertEqual(roll.consume(degrees: -20), -8.0 / 360.0, accuracy: 1e-9)
        XCTAssertEqual(RollDetentTracker.crossed(from: 0.04, to: 0.16), 3)
        XCTAssertEqual(RollDetentTracker.crossed(from: 0.96, to: 1), 1)
    }
}
