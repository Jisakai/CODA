import SwiftUI
import UIKit
import CodaMusic
import CodaSession

@main
final class CodaApp: UIResponder, UIApplicationDelegate {}

@MainActor
final class CodaSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var musicSession: MusicSession?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let editorStore: CodaEditorStore
        do {
            let vocabulary = try ChordVocabulary.load(in: .main)
            let musicSession = try MusicSession(vocabulary: vocabulary)
            self.musicSession = musicSession
            editorStore = CodaEditorStore(session: musicSession)
        } catch {
            editorStore = CodaEditorStore(session: nil, startupError: "Editor could not load: \(error)")
        }
        window.rootViewController = CodaHostingController(
            rootView: CodaCanvas(store: editorStore).preferredColorScheme(.dark)
        )
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidEnterBackground(_ scene: UIScene) { musicSession?.suspend() }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Keep the engine closed after a scene transition; the next explicit
        // Play or Pencil audition creates a fresh native epoch through the session.
        musicSession?.suspend()
    }

    func sceneDidDisconnect(_ scene: UIScene) { musicSession?.suspend() }
}

private final class CodaHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // The scene queries its root controller; UIRequiresFullScreen no longer locks rotation.
    // https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key
    override var prefersInterfaceOrientationLocked: Bool { true }

#if DEBUG
    // Read actual scene/window/host geometry in UI tests, independently of
    // XCUIDevice.orientation and AX's screen-coordinate orientation.
    private var geometryReadout: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard ProcessInfo.processInfo.arguments.contains("--coda-ui-geometry") else { return }
        let readout = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        readout.text = "Scene geometry"
        readout.alpha = 0.01
        readout.isUserInteractionEnabled = false
        readout.isAccessibilityElement = true
        readout.accessibilityIdentifier = "editor.sceneGeometry"
        view.addSubview(readout)
        geometryReadout = readout
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let readout = geometryReadout, let window = view.window,
              let scene = window.windowScene else { return }
        let sizes = [scene.coordinateSpace.bounds.size, window.bounds.size, view.bounds.size]
        readout.accessibilityValue = ([scene.interfaceOrientation.isLandscape ? "landscape" : "portrait"]
            + sizes.flatMap { [String(Double($0.width)), String(Double($0.height))] })
            .joined(separator: "|")
    }
#endif
}
