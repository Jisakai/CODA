import SwiftUI
import CodaMusic

/// Named visual and interaction tuning from SPEC.md and docs/DESIGN.md.
enum CodaDesignTokens {
    enum Colors {
        static let oled = Color(red: 0, green: 0, blue: 0)
        static let darkGlass = Color(red: 22.0 / 255, green: 22.0 / 255, blue: 24.0 / 255)
        static let coalGutter = Color(red: 12.0 / 255, green: 12.5 / 255, blue: 14.0 / 255)
        static let coalScale = Color(red: 11.0 / 255, green: 11.5 / 255, blue: 13.0 / 255)
        static let primaryInk = Color(red: 226.0 / 255, green: 226.0 / 255, blue: 236.0 / 255)
        static let mutedInk = Color(red: 130.0 / 255, green: 134.0 / 255, blue: 149.0 / 255)
        static let mutedInkAlternate = Color(red: 114.0 / 255, green: 118.0 / 255, blue: 133.0 / 255)
        static let chord = Color(red: 132.0 / 255, green: 155.0 / 255, blue: 181.0 / 255)
        static let chordAlternate = Color(red: 151.0 / 255, green: 142.0 / 255, blue: 176.0 / 255)
        static let bass = Color(red: 130.0 / 255, green: 167.0 / 255, blue: 146.0 / 255)
        static let melody = Color(red: 158.0 / 255, green: 146.0 / 255, blue: 184.0 / 255)
        static let sidekickAccent = Color(red: 221.0 / 255, green: 183.0 / 255, blue: 255.0 / 255)
        static let sidekick = sidekickAccent
        static let danger = Color(red: 201.0 / 255, green: 138.0 / 255, blue: 138.0 / 255)

        static func layerTint(_ layer: MusicLayer) -> Color {
            switch layer {
            case .chords: return chord
            case .bass: return bass
            case .melody: return melody
            }
        }
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

        /// Apple Fluid Interfaces springs (emilkowalski/skills/apple-design §4):
        /// - Critically damped (`dampingFraction: 1.0`) for default UI, popovers, and tabs.
        /// - Slight momentum settle (`dampingFraction: 0.84`) for drawers and sheets.
        static let uiSpring: Animation = .spring(response: 0.34, dampingFraction: 1.0)
        static let sheetSpring: Animation = .spring(response: 0.32, dampingFraction: 0.84)
        static let snappySpring: Animation = .spring(response: 0.24, dampingFraction: 0.92)
        static let pressSpring: Animation = .interactiveSpring(response: 0.16, dampingFraction: 0.88)

        /// Apple WWDC 2018 exponential-decay momentum projection (apple-design §6).
        static func project(velocity: CGFloat, decelerationRate: CGFloat = 0.996) -> CGFloat {
            (velocity / 1000.0) * decelerationRate / (1.0 - decelerationRate)
        }

        /// Apple progressive rubber-banding resistance at soft boundaries (apple-design §9).
        static func rubberband(overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
            guard dimension > 0 else { return 0 }
            return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
        }
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
        static let radialSymbolSize: CGFloat = 12.5
        static let radialSymbolWeight = Font.Weight.medium
        static let radialInnerRadius = 50.0
        static let radialOuterRadius = 96.0
        static let radialInnerBand = 36.0
        static let radialOuterBand = 42.0
        static let radialFamilyRadius = 86.0
        static let radialFamilySpacing = 48.0
        static let radialFamilyBand = 42.0
        static let radialMargin = 8.0
        static let radialPillOpacity = 0.075
        static let radialSelectedPillOpacity = 0.18
        static let radialDisabledPillOpacity = 0.018
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

/// Apple Fluid Interfaces tactile button style (emilkowalski/skills/apple-design §1, §4):
/// Responds on pointer-down with subtle 0.965 compression and springs back smoothly on release.
struct CodaTactileButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.965
    var pressedOpacity: Double = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .animation(CodaDesignTokens.Motion.pressSpring, value: configuration.isPressed)
    }
}

/// Layered dark-studio glass surface inspired by Apple HIG & Procreate:
/// Continuous squircle corners, top specular hairline rim, and deep ambient shadow.
struct CodaStudioCardSurface: ViewModifier {
    var cornerRadius: CGFloat = CodaDesignTokens.ProcreateChrome.cardCornerRadius
    var fill: Color = CodaDesignTokens.ProcreateChrome.surfaceElevated
    var elevated: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape.fill(fill)
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                colors: [Color.white.opacity(elevated ? 0.065 : 0.04), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(elevated ? 0.16 : 0.11), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: CodaDesignTokens.ProcreateChrome.bevelLineWidth
                )
            )
            .shadow(
                color: elevated ? CodaDesignTokens.ProcreateChrome.shadowColor : .black.opacity(0.22),
                radius: elevated ? CodaDesignTokens.ProcreateChrome.shadowRadius : 8,
                x: 0,
                y: elevated ? CodaDesignTokens.ProcreateChrome.shadowY : 3
            )
    }
}

extension View {
    func codaStudioCard(
        cornerRadius: CGFloat = CodaDesignTokens.ProcreateChrome.cardCornerRadius,
        fill: Color = CodaDesignTokens.ProcreateChrome.surfaceElevated,
        elevated: Bool = false
    ) -> some View {
        modifier(CodaStudioCardSurface(cornerRadius: cornerRadius, fill: fill, elevated: elevated))
    }
}
