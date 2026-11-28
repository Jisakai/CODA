import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Installs device-filtered UIKit recognizers on the hosting view. The anchor
/// itself never participates in hit testing, so finger UI controls remain live.
struct PencilInputBridge: UIViewRepresentable {
    let store: CodaEditorStore
    var onPencilDoubleTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onPencilDoubleTap: onPencilDoubleTap)
    }

    func makeUIView(context: Context) -> PencilInputAnchorView {
        let view = PencilInputAnchorView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onWindowChange = { [weak coordinator = context.coordinator] anchor in
            guard let window = anchor.window,
                  let root = window.rootViewController?.view else { return }
            coordinator?.install(on: root, window: window)
        }
        return view
    }

    func updateUIView(_ uiView: PencilInputAnchorView, context: Context) {
        context.coordinator.store = store
        context.coordinator.onPencilDoubleTap = onPencilDoubleTap
        if let window = uiView.window, let root = window.rootViewController?.view {
            context.coordinator.install(on: root, window: window)
        }
    }

    static func dismantleUIView(_ uiView: PencilInputAnchorView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var store: CodaEditorStore
        var onPencilDoubleTap: (() -> Void)?
        private weak var rootView: UIView?
        private weak var installedWindow: UIWindow?
        private var pencilSequence: PencilSequenceRecognizer?
        private var hover: UIHoverGestureRecognizer?
        private var pencilInteraction: UIPencilInteraction?
        private var pan: UIPanGestureRecognizer?
        private var pinch: UIPinchGestureRecognizer?
        private var undoTap: UITapGestureRecognizer?
        private var redoTap: UITapGestureRecognizer?
        private var hideChromeTap: UITapGestureRecognizer?
        private var canvasFeedback: UICanvasFeedbackGenerator?
        private var lastHapticTime = 0.0
        private var lastDoubleTapTime = 0.0
        private var lastDetent = 0
        private var panStart: CGPoint = .zero

        init(store: CodaEditorStore, onPencilDoubleTap: (() -> Void)? = nil) {
            self.store = store
            self.onPencilDoubleTap = onPencilDoubleTap
            super.init()
        }

        func install(on root: UIView, window: UIWindow) {
            guard installedWindow !== window || rootView !== root else { return }
            uninstall()
            rootView = root
            installedWindow = window
            canvasFeedback = UICanvasFeedbackGenerator(view: root)
            canvasFeedback?.prepare()

            let pencil = PencilSequenceRecognizer(target: self, action: #selector(handlePencilSequence(_:)))
            pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            pencil.cancelsTouchesInView = false
            pencil.delaysTouchesBegan = false
            pencil.delaysTouchesEnded = false
            pencil.delegate = self
            root.addGestureRecognizer(pencil)
            pencilSequence = pencil

            let hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover(_:)))
            hoverRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            hoverRecognizer.delegate = self
            root.addGestureRecognizer(hoverRecognizer)
            hover = hoverRecognizer

            let squeeze = UIPencilInteraction()
            squeeze.delegate = self
            squeeze.isEnabled = true
            root.addInteraction(squeeze)
            pencilInteraction = squeeze

            let navigation = UIPanGestureRecognizer(target: self, action: #selector(handleFingerPan(_:)))
            navigation.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            navigation.minimumNumberOfTouches = 1
            navigation.maximumNumberOfTouches = 1
            navigation.cancelsTouchesInView = false
            navigation.delegate = self
            root.addGestureRecognizer(navigation)
            pan = navigation

            let zoom = UIPinchGestureRecognizer(target: self, action: #selector(handleFingerPinch(_:)))
            zoom.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            zoom.cancelsTouchesInView = false
            zoom.delegate = self
            root.addGestureRecognizer(zoom)
            pinch = zoom

            undoTap = addTap(touches: 2, taps: 2, to: root, action: #selector(handleUndoTap(_:)))
            redoTap = addTap(touches: 3, taps: 2, to: root, action: #selector(handleRedoTap(_:)))
            hideChromeTap = addTap(touches: 4, taps: 1, to: root, action: #selector(handleHideChromeTap(_:)))
        }

        func uninstall() {
            guard let root = rootView else { return }
            let recognizers: [UIGestureRecognizer?] = [pencilSequence, hover, pan, pinch,
                                                        undoTap, redoTap, hideChromeTap]
            recognizers.compactMap { $0 }.forEach(root.removeGestureRecognizer)
            if let pencilInteraction { root.removeInteraction(pencilInteraction) }
            pencilSequence = nil; hover = nil; pan = nil; pinch = nil
            undoTap = nil; redoTap = nil; hideChromeTap = nil; pencilInteraction = nil
            rootView = nil; installedWindow = nil
            canvasFeedback = nil
            store.cancelRadialPreview()
            store.clearRollTracking()
        }

        private func addTap(touches: Int, taps: Int, to view: UIView,
                            action: Selector) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: action)
            recognizer.numberOfTouchesRequired = touches
            recognizer.numberOfTapsRequired = taps
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            return recognizer
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            // Observe once through an existing noncancelling recognizer. Do not
            // add a competing gesture or change routing for diagnostic capture.
            if gestureRecognizer === hideChromeTap, touch.type == .direct,
               store.uiDiagnosticsEnabled, let rootView {
                let point = touch.location(in: rootView)
                let hit = touch.view.map { "\(type(of: $0)) frame=\($0.convert($0.bounds, to: rootView))" } ?? "nil"
                if store.patternEditing, point.y < store.timelineTop, point.x > store.rootSize.width / 2 {
                    store.recordUIEvent("pattern.swing.touch at=\(point) hit=\(hit) shortcuts=\(!store.shouldIgnoreFingerShortcut)")
                } else {
                    store.recordUIEvent("touch.begin at=\(point) hit=\(hit) popup=\(store.popup?.rawValue ?? "nil") muted=\(store.controls.muted)")
                }
            }
            if gestureRecognizer === undoTap || gestureRecognizer === redoTap || gestureRecognizer === hideChromeTap {
                return touch.type == .direct && !store.shouldIgnoreFingerShortcut
            }
            if gestureRecognizer === pencilSequence {
                guard touch.type == .pencil, let rootView else { return false }
                return store.acceptsPencilLocation(touch.location(in: rootView))
            }
            if gestureRecognizer === hover {
                guard touch.type == .pencil, let rootView else { return false }
                return store.acceptsPencilLocation(touch.location(in: rootView))
            }
            if gestureRecognizer === pan || gestureRecognizer === pinch {
                guard touch.type == .direct, let rootView else { return false }
                let point = touch.location(in: rootView)
                let accepted = store.beginFingerNavigation(at: point)
                if store.uiDiagnosticsEnabled, store.patternEditing,
                   point.y < store.timelineTop, point.x > store.rootSize.width / 2 {
                    let name = gestureRecognizer === pan ? "pan" : "pinch"
                    store.recordUIEvent("pattern.swing.admit.\(name) accepted=\(accepted) at=\(point)")
                }
                if accepted && gestureRecognizer === pan { panStart = point }
                return accepted
            }
            return touch.type == .direct
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
            dispatchPencilDoubleTap()
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            dispatchPencilDoubleTap()
        }

        private func dispatchPencilDoubleTap() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastDoubleTapTime >= 0.08 else { return }
            lastDoubleTapTime = now
            if let onPencilDoubleTap {
                onPencilDoubleTap()
            } else {
                store.handlePencilDoubleTap()
            }
            emitDetentIfNeeded()
        }

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            // Squeeze hoverPose may be absent when the system assigns it to a
            // Shortcut; the store then uses only its last valid Pencil location.
            if squeeze.phase == .began {
                store.openSqueeze(at: squeeze.hoverPose?.location)
            } else if squeeze.phase == .ended {
                store.finishSqueeze(at: squeeze.hoverPose?.location)
                emitDetentIfNeeded()
            } else if squeeze.phase == .cancelled {
                store.pencilTouchCancelled()
            }
        }

        @objc private func handlePencilSequence(_ recognizer: PencilSequenceRecognizer) {
            guard let rootView else { return }
            let point = recognizer.location(in: rootView)
            switch recognizer.state {
            case .began:
                canvasFeedback?.prepare()
                store.pencilTouchBegan(at: point)
                if let angle = recognizer.latestRollAngle { store.pencilHover(at: point, rollAngle: angle) }
            case .changed:
                store.pencilTouchMoved(to: point)
                if let angle = recognizer.latestRollAngle { store.pencilHover(at: point, rollAngle: angle) }
            case .ended:
                if let angle = recognizer.latestRollAngle { store.pencilHover(at: point, rollAngle: angle) }
                store.pencilTouchEnded(at: point)
            case .cancelled, .failed: store.pencilTouchCancelled()
            default: break
            }
            emitDetentIfNeeded()
        }

        @objc private func handlePencilHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let rootView else { return }
            switch recognizer.state {
            case .began:
                canvasFeedback?.prepare()
                store.pencilHover(at: recognizer.location(in: rootView), rollAngle: Double(recognizer.rollAngle))
                emitDetentIfNeeded()
            case .changed:
                store.pencilHover(at: recognizer.location(in: rootView), rollAngle: Double(recognizer.rollAngle))
                emitDetentIfNeeded()
            case .ended, .cancelled, .failed:
                store.clearRollTracking()
                store.cancelRadialPreview()
            default: break
            }
        }

        @objc private func handleFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let rootView else { return }
            let point = recognizer.location(in: rootView)
            switch recognizer.state {
            case .began, .changed:
                // Preserve the touch-down point from shouldReceive, including
                // motion before UIKit crosses its recognition threshold.
                let delta = recognizer.translation(in: rootView)
                store.routeFingerPan(from: panStart, to: point, translation: delta)
                recognizer.setTranslation(.zero, in: rootView)
            default: break
            }
        }

        @objc private func handleFingerPinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let rootView else { return }
            if recognizer.state == .changed {
                store.routeFingerPinch(scale: recognizer.scale, at: recognizer.location(in: rootView))
                recognizer.scale = 1
            }
        }

        @objc private func handleUndoTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .recognized else { return }
            store.routeFingerGesture(touchCount: recognizer.numberOfTouchesRequired, tapCount: recognizer.numberOfTapsRequired)
        }

        @objc private func handleRedoTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .recognized else { return }
            store.routeFingerGesture(touchCount: recognizer.numberOfTouchesRequired, tapCount: recognizer.numberOfTapsRequired)
        }

        @objc private func handleHideChromeTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .recognized else { return }
            store.routeFingerGesture(touchCount: recognizer.numberOfTouchesRequired, tapCount: recognizer.numberOfTapsRequired)
        }

        private func emitDetentIfNeeded() {
            guard store.pencilFeedbackSerial != lastDetent else { return }
            lastDetent = store.pencilFeedbackSerial
            guard store.gestureSettings.hapticsEnabled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastHapticTime >= CodaDesignTokens.Input.hapticMinimumInterval else { return }
            lastHapticTime = now
            guard let point = store.transientPoint ?? store.lastPencilLocation else { return }
            // Official DocC documents these canvas events, not a Pencil
            // intensity setter. Default/end-point emphasis also remains visual.
            if store.pencilFeedbackIsCompletion {
                canvasFeedback?.pathCompleted(at: point)
            } else {
                canvasFeedback?.alignmentOccurred(at: point)
            }
            canvasFeedback?.prepare()
        }
    }
}

final class PencilInputAnchorView: UIView {
    var onWindowChange: ((PencilInputAnchorView) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(self)
    }
}

private final class PencilSequenceRecognizer: UIGestureRecognizer {
    private(set) var initialLocation = CGPoint.zero
    private(set) var latestLocation = CGPoint.zero
    private(set) var latestRollAngle: Double?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, touch.type == .pencil else {
            state = .failed
            return
        }
        initialLocation = touch.location(in: view)
        latestLocation = initialLocation
        latestRollAngle = Double(touch.rollAngle)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { state = .cancelled; return }
        latestLocation = touch.location(in: view)
        latestRollAngle = Double(touch.rollAngle)
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, touch.type == .pencil {
            latestLocation = touch.location(in: view)
            latestRollAngle = Double(touch.rollAngle)
        }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        initialLocation = .zero
        latestLocation = .zero
        latestRollAngle = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
