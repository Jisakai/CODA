import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CodaMusic

extension MusicLayer {
    var displayName: String {
        switch self {
        case .bass: "Bass"
        case .chords: "Chord"
        case .melody: "Melody"
        }
    }

    var uppercaseLabel: String {
        switch self {
        case .bass: "BASS"
        case .chords: "CHORDS"
        case .melody: "MELODY"
        }
    }

    var accentColor: Color {
        switch self {
        case .bass: CodaDesignTokens.Colors.bass
        case .chords: CodaDesignTokens.Colors.chord
        case .melody: CodaDesignTokens.Colors.melody
        }
    }

    var symbolName: String {
        switch self {
        case .bass: "waveform.path.ecg"
        case .chords: "square.stack.3d.up.fill"
        case .melody: "music.note"
        }
    }
}

/// Compact monochrome Procreate-style studio icons and vector glyphs.
enum ProcreateIcons {
    /// Stacked chord bars glyph (custom vector for crisp rendering at 12-16pt).
    struct ChordStackGlyph: View {
        var body: some View {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1).frame(width: 11, height: 2.2)
                RoundedRectangle(cornerRadius: 1).frame(width: 11, height: 2.2)
                RoundedRectangle(cornerRadius: 1).frame(width: 11, height: 2.2)
            }
        }
    }

    /// Low-register bass waveform glyph.
    struct BassWaveGlyph: View {
        var body: some View {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
        }
    }

    /// Single melody note glyph.
    struct MelodyNoteGlyph: View {
        var body: some View {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .bold))
        }
    }

    /// Procreate-style 4-square Gallery icon.
    struct GalleryGlyph: View {
        var body: some View {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    /// Procreate-style Wrench (Actions / App Settings) icon.
    struct WrenchGlyph: View {
        var body: some View {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    /// Inspector / Sidekick sparkle-panel glyph.
    struct InspectorGlyph: View {
        var hasGhosts: Bool = false
        var body: some View {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                if hasGhosts {
                    Circle()
                        .fill(CodaDesignTokens.Colors.sidekickAccent)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    @ViewBuilder
    static func layerGlyph(for layer: MusicLayer) -> some View {
        switch layer {
        case .bass: BassWaveGlyph()
        case .chords: ChordStackGlyph()
        case .melody: MelodyNoteGlyph()
        }
    }

    /// Crisp SF Symbols for the 6-slot piano-roll squeeze radial menu so text never clips in 32pt circles.
    static func rollRadialSymbol(for slot: Int) -> (symbol: String, title: String) {
        switch slot {
        case 0: ("pencil.and.outline", "Draw/Erase")
        case 1: ("scissors", "Razor")
        case 2: ("lasso", "Select")
        case 3: ("doc.on.doc.fill", "Copy")
        case 4: ("clipboard.fill", "Paste")
        case 5: ("arrow.up.arrow.down", "Pattern")
        default: ("circle.fill", "")
        }
    }
}

/// Upward-pointing triangular pointer for Procreate-style anchored popovers.
struct ProcreatePopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Payload exported via UIKit `UIActivityViewController` (MIDI or `.coda.json`).
struct ExportFilePayload: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let data: Data
    let contentType: UTType

    func writeTemporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coda-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Presents native UIKit share / document-import controllers directly from the
/// active window's root view controller without using SwiftUI `.sheet`.
@MainActor
enum CodaUIKitFilePresenter {
    static func presentShare(payload: ExportFilePayload, completion: @escaping () -> Void) {
        guard let root = activeRootViewController() else { completion(); return }
        do {
            let fileURL = try payload.writeTemporaryFile()
            let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            controller.completionWithItemsHandler = { _, _, _, _ in
                Task { @MainActor in completion() }
            }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX, y: 64, width: 1, height: 1)
                popover.permittedArrowDirections = [.up]
            }
            root.present(controller, animated: true)
        } catch {
            completion()
        }
    }

    static func presentJSONImporter(onImport: @escaping (Result<Data, Error>) -> Void) {
        guard let root = activeRootViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        let delegate = DocumentPickerCoordinator(onDataResult: onImport)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &DocumentPickerCoordinator.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        root.present(picker, animated: true)
    }

    static func presentSoundFontImporter(onPickURL: @escaping (URL) -> Void) {
        guard let root = activeRootViewController() else { return }
        let sf2 = UTType(filenameExtension: "sf2") ?? .data
        let dls = UTType(filenameExtension: "dls") ?? .data
        let aupreset = UTType(filenameExtension: "aupreset") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [sf2, dls, aupreset, .item], asCopy: false)
        let delegate = DocumentPickerCoordinator(onURLResult: onPickURL)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &DocumentPickerCoordinator.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        root.present(picker, animated: true)
    }

    private static func activeRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}

private final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    private let onDataResult: ((Result<Data, Error>) -> Void)?
    private let onURLResult: ((URL) -> Void)?

    init(onDataResult: @escaping (Result<Data, Error>) -> Void) {
        self.onDataResult = onDataResult
        self.onURLResult = nil
    }

    init(onURLResult: @escaping (URL) -> Void) {
        self.onDataResult = nil
        self.onURLResult = onURLResult
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if let onURLResult {
            onURLResult(url)
            return
        }
        guard let onDataResult else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            onDataResult(.success(data))
        } catch {
            onDataResult(.failure(error))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
}
