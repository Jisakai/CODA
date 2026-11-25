import SwiftUI

/// M0 design tokens. Geometry follows docs/DESIGN.md; no future UI is drawn yet.
enum CodaDesignTokens {
    enum Colors {
        static let oled = Color(red: 0, green: 0, blue: 0)
        static let darkGlass = Color(red: 22.0 / 255, green: 22.0 / 255, blue: 24.0 / 255).opacity(0.90)
        static let coalGutter = Color(red: 24.0 / 255, green: 25.0 / 255, blue: 29.0 / 255)
        static let coalScale = Color(red: 21.0 / 255, green: 22.0 / 255, blue: 25.0 / 255)
        static let primaryInk = Color(red: 226.0 / 255, green: 226.0 / 255, blue: 236.0 / 255)
        static let mutedInk = Color(red: 130.0 / 255, green: 134.0 / 255, blue: 149.0 / 255)
        static let mutedInkAlternate = Color(red: 114.0 / 255, green: 118.0 / 255, blue: 133.0 / 255)
        static let chord = Color(red: 132.0 / 255, green: 155.0 / 255, blue: 181.0 / 255)
        static let chordAlternate = Color(red: 151.0 / 255, green: 142.0 / 255, blue: 176.0 / 255)
        static let bass = Color(red: 130.0 / 255, green: 167.0 / 255, blue: 146.0 / 255)
        static let melody = Color(red: 158.0 / 255, green: 146.0 / 255, blue: 184.0 / 255)
        static let sidekickAccent = Color(red: 221.0 / 255, green: 183.0 / 255, blue: 255.0 / 255)
    }

    enum Radii {
        static let innerPill: CGFloat = 4
        static let control: CGFloat = 6
        static let card: CGFloat = 8
    }

    enum Typography {
        static let noteAndLabelSize: CGFloat = 10
        static let chipAndReadoutSize: CGFloat = 12
        static let chordNameSize: CGFloat = 13
        static let menuItemSize: CGFloat = 15
        static let labelWeight = Font.Weight.semibold
        static let chordNameWeight = Font.Weight.bold

        static let lightFontPostScriptName = "PlusJakartaSans-Light"
        static let regularFontPostScriptName = "PlusJakartaSans-Regular"
        static let mediumFontPostScriptName = "PlusJakartaSans-Medium"
        static let semiBoldFontPostScriptName = "PlusJakartaSans-SemiBold"
        static let boldFontPostScriptName = "PlusJakartaSans-Bold"
        static let extraBoldFontPostScriptName = "PlusJakartaSans-ExtraBold"
        static let wordmarkSize: CGFloat = 20
        static let wordmarkTracking: CGFloat = 0.2
        static let wordmarkOpacity: Double = 0.72
    }

    enum Geometry {
        static let topBarHeight: CGFloat = 52
        static let timelineHeight: CGFloat = 20
        static let chordStripHeight: CGFloat = 104
        static let pitchGutterWidth: CGFloat = 56
        static let pianoRollSemitoneHeight: CGFloat = 22
        static let minimumZoomedSemitoneHeight: CGFloat = 14
        static let maximumZoomedSemitoneHeight: CGFloat = 36
    }
}
