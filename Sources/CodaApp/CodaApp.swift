import SwiftUI
import UIKit

@main
struct CodaApp: App {
    var body: some Scene {
        WindowGroup {
            CodaCanvas()
                .preferredColorScheme(.dark)
        }
    }
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
