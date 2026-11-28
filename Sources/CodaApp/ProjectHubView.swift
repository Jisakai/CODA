import SwiftUI
import CodaMusic
import CodaSession

/// Procreate-style full-screen dark Gallery / Project Hub (SPEC §19, Nov 28 redesign).
struct ProjectHubView: View {
    @Bindable var store: CodaEditorStore
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var renamingID: String?
    @State private var renameDraft = ""
    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    private var filteredProjects: [ProjectSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.projectHub.projects }
        return store.projectHub.projects.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.keyDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            CodaDesignTokens.Colors.oled.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 24)
                    .frame(height: 60)
                    .background(CodaDesignTokens.ProcreateChrome.surfaceDeep)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)
                    }

                if let recovery = store.autosaveRecoveryDocument {
                    autosaveBanner(recovery)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }

                ScrollView {
                    if filteredProjects.isEmpty {
                        emptyGalleryState
                            .padding(.top, 96)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(filteredProjects) { project in
                                projectCard(project)
                            }
                        }
                        .padding(24)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hub.gallery")
    }

    private var headerBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("coda")
                    .font(CodaDesignTokens.Typography.font(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                Text("Gallery")
                    .font(CodaDesignTokens.Typography.font(size: 13, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                TextField("Search sketches", text: $searchText)
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .medium))
                    .textFieldStyle(.plain)
                    .frame(width: 170)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(CodaDesignTokens.ProcreateChrome.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.pillCornerRadius))

            if selectionMode && !selectedIDs.isEmpty {
                Button {
                    for id in selectedIDs { store.deleteProject(id: id) }
                    selectedIDs.removeAll()
                    selectionMode = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill").font(.system(size: 11, weight: .bold))
                        Text("Delete (\(selectedIDs.count))")
                            .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(CodaDesignTokens.Colors.danger)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(CodaDesignTokens.Colors.danger.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.pillCornerRadius))
                }
                .accessibilityIdentifier("hub.deleteSelected")
            }

            Button {
                selectionMode.toggle()
                if !selectionMode { selectedIDs.removeAll() }
            } label: {
                Text(selectionMode ? "Done" : "Select")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                    .foregroundStyle(selectionMode ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.primaryInk)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(CodaDesignTokens.ProcreateChrome.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.pillCornerRadius))
            }
            .accessibilityIdentifier("hub.select")

            Button {
                CodaUIKitFilePresenter.presentJSONImporter { result in
                    Task { @MainActor in
                        switch result {
                        case .success(let data): store.importProjectJSON(data: data)
                        case .failure(let error): store.inlineError = error.localizedDescription
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                    Text("Import").font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(CodaDesignTokens.ProcreateChrome.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.pillCornerRadius))
            }
            .accessibilityIdentifier("hub.import")

            Button {
                store.createNewProject(name: "")
                store.projectHubOpen = false
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text("New Sketch").font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(CodaDesignTokens.Colors.primaryInk,
                            in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.pillCornerRadius))
            }
            .accessibilityIdentifier("hub.newSketch")

            Button {
                store.projectHubOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(CodaDesignTokens.ProcreateChrome.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.pillCornerRadius))
            }
            .accessibilityLabel("Return to canvas")
            .accessibilityIdentifier("hub.close")
        }
    }

    private func autosaveBanner(_ recovery: CodaProjectDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unsaved recovery sketch available")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                Text("\"\(recovery.name)\" · \(recovery.chordRegions.count) chords · \(Int(recovery.tempo.rounded())) BPM")
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            Spacer()
            Button {
                store.restoreAutosaveRecovery()
                store.projectHubOpen = false
            } label: {
                Text("Restore")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(CodaDesignTokens.Colors.sidekickAccent, in: Capsule())
            }
            .accessibilityIdentifier("hub.recovery.restore")
            Button {
                store.dismissAutosaveRecovery()
            } label: {
                Text("Dismiss")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .padding(.horizontal, 10).frame(height: 28)
            }
            .accessibilityIdentifier("hub.recovery.dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CodaDesignTokens.ProcreateChrome.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.cardCornerRadius)
                .stroke(CodaDesignTokens.Colors.sidekickAccent.opacity(0.35), lineWidth: 0.75)
        )
        .accessibilityIdentifier("hub.recoveryBanner")
    }

    private var emptyGalleryState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk.opacity(0.6))
            Text("No saved sketches yet")
                .font(CodaDesignTokens.Typography.font(size: 16, weight: .bold))
            Text("Save your current canvas or start a fresh progression.")
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .medium))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            HStack(spacing: 10) {
                Button {
                    store.saveCurrentProject()
                } label: {
                    Text("Save Current Sketch")
                        .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(CodaDesignTokens.Colors.chord.opacity(0.22),
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                }
                Button {
                    store.createNewProject(name: "")
                    store.projectHubOpen = false
                } label: {
                    Text("+ New Sketch")
                        .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(CodaDesignTokens.Colors.primaryInk,
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                }
            }
        }
    }

    private func projectCard(_ project: ProjectSummary) -> some View {
        let isActive = store.projectHub.activeProjectID == project.id
        let isSelected = selectedIDs.contains(project.id)
        return VStack(alignment: .leading, spacing: 10) {
            // Mini chord-bar canvas preview
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(CodaDesignTokens.Colors.oled)
                    .frame(height: 112)
                    .overlay {
                        if project.previewChordNames.isEmpty {
                            Text("Empty canvas")
                                .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                                .foregroundStyle(CodaDesignTokens.Colors.mutedInk.opacity(0.5))
                        } else {
                            VStack(spacing: 8) {
                                HStack(spacing: 5) {
                                    ForEach(Array(project.previewChordNames.prefix(4).enumerated()), id: \.offset) { idx, symbol in
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill((idx.isMultiple(of: 2) ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.chordAlternate).opacity(0.24))
                                            .overlay {
                                                Text(symbol)
                                                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                                                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                                                    .lineLimit(1).minimumScaleFactor(0.7)
                                                    .padding(.horizontal, 4)
                                            }
                                            .frame(height: 36)
                                    }
                                }
                                // Mini piano-roll silhouette bars
                                VStack(spacing: 3) {
                                    HStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 2).fill(CodaDesignTokens.Colors.chord.opacity(0.45)).frame(height: 5)
                                        RoundedRectangle(cornerRadius: 2).fill(CodaDesignTokens.Colors.melody.opacity(0.4)).frame(height: 5)
                                    }
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2).fill(CodaDesignTokens.Colors.bass.opacity(0.45)).frame(height: 5)
                                        RoundedRectangle(cornerRadius: 2).fill(CodaDesignTokens.Colors.chord.opacity(0.35)).frame(height: 5)
                                    }
                                }
                            }
                            .padding(10)
                        }
                    }

                if selectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk)
                        .padding(8)
                } else if isActive {
                    Text("OPEN")
                        .font(CodaDesignTokens.Typography.font(size: 9, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.chord)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(CodaDesignTokens.Colors.chord.opacity(0.16), in: Capsule())
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                if selectionMode {
                    if isSelected { selectedIDs.remove(project.id) } else { selectedIDs.insert(project.id) }
                } else {
                    store.openProject(id: project.id)
                    store.projectHubOpen = false
                }
            }

            // Title / inline rename
            if renamingID == project.id {
                HStack(spacing: 6) {
                    TextField("Sketch name", text: $renameDraft)
                        .font(CodaDesignTokens.Typography.font(size: 13, weight: .bold))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(CodaDesignTokens.ProcreateChrome.surfaceDeep, in: RoundedRectangle(cornerRadius: 5))
                        .onSubmit {
                            store.renameProject(id: project.id, to: renameDraft)
                            renamingID = nil
                        }
                    Button {
                        store.renameProject(id: project.id, to: renameDraft)
                        renamingID = nil
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(CodaDesignTokens.Colors.chord)
                    }
                }
            } else {
                Text(project.name)
                    .font(CodaDesignTokens.Typography.font(size: 13, weight: .bold))
                    .lineLimit(1)
            }

            // Metadata row
            Text("\(project.keyDisplayName) · \(Int(project.tempo.rounded())) BPM · \(project.barCount) bars")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .lineLimit(1)

            HStack {
                Text(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(CodaDesignTokens.Typography.font(size: 9, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInkAlternate)
                Spacer()
            }

            // Compact action strip
            HStack(spacing: 6) {
                cardAction(symbol: "pencil", label: "Rename") {
                    renameDraft = project.name
                    renamingID = project.id
                }
                cardAction(symbol: "plus.square.on.square", label: "Duplicate") {
                    store.duplicateProject(id: project.id)
                }
                cardAction(symbol: "waveform", label: "Export WAV") {
                    store.exportWAVForProject(id: project.id)
                }
                cardAction(symbol: "music.note.list", label: "Export MIDI") {
                    store.exportMIDIForProject(id: project.id)
                }
                cardAction(symbol: "square.and.arrow.up", label: "Export JSON") {
                    store.exportJSONForProject(id: project.id)
                }
                Spacer()
                cardAction(symbol: "trash", label: "Delete", destructive: true) {
                    store.deleteProject(id: project.id)
                }
            }
        }
        .padding(12)
        .codaStudioCard(
            cornerRadius: CodaDesignTokens.ProcreateChrome.cardCornerRadius,
            fill: CodaDesignTokens.ProcreateChrome.surfaceElevated,
            elevated: isSelected
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodaDesignTokens.ProcreateChrome.cardCornerRadius, style: .continuous)
                .stroke(isSelected ? CodaDesignTokens.Colors.chord : Color.clear, lineWidth: 1.5)
        )
        .buttonStyle(CodaTactileButtonStyle())
        .accessibilityIdentifier("hub.project.\(project.id)")
    }

    private func cardAction(symbol: String, label: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.mutedInk)
                .frame(width: 26, height: 24)
                .background(CodaDesignTokens.ProcreateChrome.surfaceControl.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityLabel(label)
    }
}
