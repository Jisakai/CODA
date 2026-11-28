import SwiftUI

/// Named visual and interaction tuning from SPEC.md and docs/DESIGN.md.
enum CodaDesignTokens {
    enum Colors {
        static let oled = Color(red: 0, green: 0, blue: 0)
        static let darkGlass = Color(red: 22.0 / 255, green: 22.0 / 255, blue: 24.0 / 255)
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
        static let danger = Color(red: 201.0 / 255, green: 138.0 / 255, blue: 138.0 / 255)
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

        static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            let name: String
            switch weight {
            case .light: name = lightFontPostScriptName
            case .medium: name = mediumFontPostScriptName
            case .semibold: name = semiBoldFontPostScriptName
            case .bold: name = boldFontPostScriptName
            case .heavy, .black: name = extraBoldFontPostScriptName
            default: name = regularFontPostScriptName
            }
            return .custom(name, size: size)
        }
    }

    enum Geometry {
        static let topBarHeight: CGFloat = 52
        static let timelineHeight: CGFloat = 20
        static let chordStripHeight: CGFloat = 104
        static let pitchGutterWidth: CGFloat = 56
        static let pianoRollTopMIDI = 76
        static let pianoRollSemitoneHeight: CGFloat = 22
        static let minimumZoomedSemitoneHeight: CGFloat = 14
        static let maximumZoomedSemitoneHeight: CGFloat = 36
        static let topBarHorizontalPadding: CGFloat = 10
        static let topBarControlHeight: CGFloat = 32
        static let topBarControlGap: CGFloat = 8
        static let playWidth: CGFloat = 56
        static let playHeight: CGFloat = 32
        static let chordInset: CGFloat = 6
        static let chordResizeHandleWidth: CGFloat = 12
        static let noteMicroInset: CGFloat = 1.5
        static let timelineHeaderWidth: CGFloat = pitchGutterWidth
        static let drawerMinWidth: CGFloat = 360
        static let drawerMaxWidth: CGFloat = 440
        static let drawerFraction: CGFloat = 0.30
        static let knobTouchSize: CGFloat = 52
        static let radialMinimumRadius: CGFloat = 64
        static let radialMaximumRadius: CGFloat = 216
        static let radialStrokeWidth: CGFloat = 40
        static let detentDotSize: CGFloat = 6
        static let strongDetentDotSize: CGFloat = 8
    }

    enum Motion {
        static let fade: Double = 0.12
        static let radial: Double = 0.10
        static let drawerDuration: Double = 0.22
    }

    enum Input {
        static let holdDuration: Double = 0.4
        static let holdMoveTolerance: CGFloat = 8
        static let holdRowHeight: CGFloat = 40
        static let holdMenuWidth: CGFloat = 224
        static let holdDividerHeight: CGFloat = 1
        static let radialPreviewInterval: Double = 0.15
        static let previewRetryInterval: Double = 0.035
        static let previewRetryAttempts = 4
        static let hapticMinimumInterval: Double = 0.035
        static let barrelDeadZoneDegrees: Double = 12
        static let knobDetentSpacing: Double = 0.05
        static let navigationEdgeWidth: CGFloat = 20
        static let navigationPanThreshold: CGFloat = 40
    }

    enum EditorSurface {
        static let patternReadoutHorizontalPadding: CGFloat = 8
        static let patternReadoutVerticalPadding: CGFloat = 4
        static let acrylicTint = 0.045
        static let acrylicHighlight = 0.025
        static let elevationRadius: CGFloat = 18
        static let elevationOffset: CGFloat = 6
        static let popupGap = 8.0
        static let popupWidth: CGFloat = 288
        static let popupPadding: CGFloat = 16
        static let keyboardNaturalOpacity = 0.10
        static let keyboardAccidentalOpacity = 0.02
        static let keyboardAccidentalWidth: CGFloat = 40
        static let keyboardLabelInset: CGFloat = 5
        static let chordDetailSize: CGFloat = 10
        static let chordDetailLines = 3
        static let toolIconSize: CGFloat = 23
        static let toolIconWeight = Font.Weight.black
        static let radialInnerRadius = 84.0
        static let radialOuterRadius = 136.0
        static let radialInnerBand = 40.0
        static let radialOuterBand = 48.0
        static let radialFamilyRadius = 132.0
        static let radialFamilySpacing = 64.0
        static let radialFamilyBand = 48.0
        static let radialMargin = 8.0
        static let radialPillOpacity = 0.05
        static let radialSelectedPillOpacity = 0.13
        static let radialDisabledPillOpacity = 0.015
        static let drawerReservedFraction: CGFloat = 0.5
        static let drawerPadding: CGFloat = 20
        static let drawerSectionGap: CGFloat = 24
        static let drawerControlGap: CGFloat = 18
        static let drawerPresetHeight: CGFloat = 56
        static let drawerMacroDiameter: CGFloat = 52
        static let drawerKnobDiameter: CGFloat = 42
        static let drawerTabWidth: CGFloat = 24
        static let drawerTabHeight: CGFloat = 64
        static let drawerHandleWidth: CGFloat = 4
        static let drawerHandleHeight: CGFloat = 40
        static let drawerCloseSize: CGFloat = 32
        static let fxRowHeight: CGFloat = 40
    }

    /// Procreate-style iPadOS dark studio chrome tokens (Nov 28 visual redesign).
    /// Complements the preserved base tokens without introducing yellow or native materials.
    enum ProcreateChrome {
        static let surfaceBase = Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)      // #1C1C1E
        static let surfaceElevated = Color(red: 36.0 / 255, green: 36.0 / 255, blue: 38.0 / 255)  // #242426
        static let surfaceControl = Color(red: 46.0 / 255, green: 46.0 / 255, blue: 50.0 / 255)   // #2E2E32
        static let surfaceDeep = Color(red: 18.0 / 255, green: 18.0 / 255, blue: 20.0 / 255)      // #121214
        static let bevelHighlight = Color.white.opacity(0.08)
        static let bevelSubtle = Color.white.opacity(0.05)
        static let divider = Color.white.opacity(0.07)
        static let activePillFill = Color.white.opacity(0.11)
        static let inactivePillFill = Color.white.opacity(0.045)
        static let shadowColor = Color.black.opacity(0.48)
        static let shadowRadius: CGFloat = 20
        static let shadowY: CGFloat = 8
        static let popoverCornerRadius: CGFloat = 12
        static let cardCornerRadius: CGFloat = 10
        static let pillCornerRadius: CGFloat = 7
        static let bevelLineWidth: CGFloat = 0.5
        static let collapsedSynthBarHeight: CGFloat = 28

        static func uiFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        static func monoFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
