import SwiftUI
import UIKit

@main
final class CodaApp: UIResponder, UIApplicationDelegate {}

final class CodaSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = CodaHostingController(
            rootView: CodaCanvas().preferredColorScheme(.dark)
        )
        self.window = window
        window.makeKeyAndVisible()
    }
}

private final class CodaHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // The scene queries its root controller; UIRequiresFullScreen no longer locks rotation.
    // https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key
    override var prefersInterfaceOrientationLocked: Bool { true }
}

private struct CodaCanvas: View {
    var body: some View {
        ZStack {
            CodaDesignTokens.Colors.oled

            Text("coda")
                .font(
                    .custom(
                        CodaDesignTokens.Typography.lightFontPostScriptName,
                        size: CodaDesignTokens.Typography.wordmarkSize
                    )
                )
                .tracking(CodaDesignTokens.Typography.wordmarkTracking)
                .foregroundStyle(
                    CodaDesignTokens.Colors.primaryInk.opacity(
                        CodaDesignTokens.Typography.wordmarkOpacity
                    )
                )
                .accessibilityValue(
                    UIFont(
                        name: CodaDesignTokens.Typography.lightFontPostScriptName,
                        size: CodaDesignTokens.Typography.wordmarkSize
                    ) == nil ? "font-missing" : "font-registered"
                )
                .accessibilityIdentifier("coda.wordmark")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CodaDesignTokens.Colors.oled)
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}
