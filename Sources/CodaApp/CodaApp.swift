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
}
