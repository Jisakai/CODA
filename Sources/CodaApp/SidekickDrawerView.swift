import SwiftUI
import CodaMusic
import CodaSidekick

/// Full-height right drawer dedicated 100% to the AI Sidekick (`coda`, SPEC §14).
/// No synth controls live here — synth & plugin controls live in `BottomSynthRackView`.
struct SidekickDrawerView: View {
    @Bindable var store: CodaEditorStore
    @State private var promptDraft = ""

    private let quickPrompts = [
        "4-bar neo-soul progression",
        "Darker turnaround for bar 4",
        "Add lush 9ths & 11ths",
        "Bridge in relative major"
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)

            modelDownloadBanner

            if !store.sidekick.activeGhosts.isEmpty {
                ghostBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)
            }

            messagesScrollView

            quickPromptStrip
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)

            inputBar
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .buttonStyle(CodaTactileButtonStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidekick.drawer")
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
                Text("coda")
                    .font(CodaDesignTokens.Typography.font(size: 14, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(CodaDesignTokens.Colors.sidekickAccent.opacity(0.14), in: Capsule())

            modelStatusPill

            Spacer(minLength: 4)

            if !store.sidekick.messages.isEmpty {
                Button {
                    store.sidekick.clearConversation()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Clear conversation")
                .accessibilityIdentifier("sidekick.clear")
            }

            Button {
                store.openDrawer(false)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Close sidekick drawer")
            .accessibilityIdentifier("drawer.close")
        }
    }

    @ViewBuilder
    private var modelStatusPill: some View {
        switch store.sidekick.modelState {
        case .notDownloaded:
            Button {
                store.sidekick.startModelDownload()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 10, weight: .bold))
                    Text("Qwen3-4B · Get").font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                }
                .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.08), in: Capsule())
            }
            .accessibilityIdentifier("sidekick.model.download")
        case .downloading(let progress):
            Button {
                store.sidekick.cancelModelDownload()
            } label: {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(CodaDesignTokens.Colors.sidekickAccent)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .monospacedDigit()
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(CodaDesignTokens.Colors.sidekickAccent.opacity(0.14), in: Capsule())
            }
            .accessibilityIdentifier("sidekick.model.downloading")
        case .ready, .loaded:
            HStack(spacing: 4) {
                Circle().fill(CodaDesignTokens.Colors.bass).frame(width: 6, height: 6)
                Text("Qwen3-4B Ready")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.05), in: Capsule())
            .accessibilityIdentifier("sidekick.model.ready")
        case .unloadedIdle:
            Text("Qwen3-4B Idle")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.05), in: Capsule())
        case .offlineUnavailable, .memoryConstrained:
            Button {
                store.sidekick.startModelDownload()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                    Text("Retry Model")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                }
                .foregroundStyle(CodaDesignTokens.Colors.danger)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(CodaDesignTokens.Colors.danger.opacity(0.14), in: Capsule())
            }
            .accessibilityIdentifier("sidekick.model.retry")
        }
    }

    @ViewBuilder
    private var modelDownloadBanner: some View {
        switch store.sidekick.modelState {
        case .downloading(let progress):
            let info = store.sidekick.downloadProgress ?? SidekickDownloadProgress(
                fraction: progress,
                completedBytes: 0,
                totalBytes: SidekickModelConfig.estimatedDownloadBytes,
                statusText: "Downloading Qwen3-4B…"
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CodaDesignTokens.Colors.sidekickAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.statusText)
                            .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                            .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                            .lineLimit(1)
                        Text("\(info.percentInt)% · \(info.formattedBytes)")
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    }
                    Spacer(minLength: 6)
                    Button {
                        store.sidekick.cancelModelDownload()
                    } label: {
                        Text("Cancel")
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.07), in: Capsule())
                    }
                    .accessibilityIdentifier("sidekick.model.cancelBanner")
                }

                ProgressView(value: max(0.0, min(1.0, info.fraction)))
                    .progressViewStyle(.linear)
                    .tint(CodaDesignTokens.Colors.sidekickAccent)
                    .accessibilityIdentifier("sidekick.model.progressBar")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(CodaDesignTokens.Colors.sidekickAccent.opacity(0.07))
            .overlay(alignment: .bottom) {
                Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)
            }
            .accessibilityIdentifier("sidekick.model.downloadBanner")

        case .offlineUnavailable(let message), .memoryConstrained(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.danger)
                    Text("Model Download Issue")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.danger)
                    Spacer()
                    Button {
                        store.sidekick.startModelDownload()
                    } label: {
                        Text("Retry")
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                            .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.10), in: Capsule())
                    }
                }
                Text(message)
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(CodaDesignTokens.Colors.danger.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)
            }
            .accessibilityIdentifier("sidekick.model.errorBanner")

        default:
            EmptyView()
        }
    }

    private var ghostBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.sidekick.activeGhosts.count) Ghost Chord\(store.sidekick.activeGhosts.count == 1 ? "" : "s")")
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
                Text("Preview on canvas or accept into progression")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            Spacer()
            Button {
                store.acceptAllGhosts()
            } label: {
                Text("Accept All")
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(CodaDesignTokens.Colors.sidekickAccent, in: Capsule())
            }
            .accessibilityIdentifier("sidekick.acceptAllGhosts")

            Button {
                store.sidekick.dismissAllGhosts()
            } label: {
                Text("Dismiss")
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            .accessibilityIdentifier("sidekick.dismissAllGhosts")
        }
    }

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.sidekick.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask coda for harmonic ideas")
                                .font(CodaDesignTokens.Typography.font(size: 14, weight: .bold))
                            Text("Suggestions appear as non-destructive purple ghost chords on your chord strip. Your notes are never overwritten automatically.")
                                .font(CodaDesignTokens.Typography.font(size: 12, weight: .regular))
                                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                    } else {
                        ForEach(store.sidekick.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .onChange(of: store.sidekick.messages.count) { _, _ in
                if let last = store.sidekick.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: SidekickMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 28)
                Text(message.text)
                    .font(CodaDesignTokens.Typography.font(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("coda")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
                    if message.hasDirectiveGhosts {
                        Text("GHOST PROPOSAL")
                            .font(CodaDesignTokens.Typography.font(size: 9, weight: .bold))
                            .foregroundStyle(CodaDesignTokens.Colors.sidekickAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(CodaDesignTokens.Colors.sidekickAccent.opacity(0.14), in: Capsule())
                    }
                }
                Text(message.text.isEmpty ? "Thinking…" : message.text)
                    .font(CodaDesignTokens.Typography.font(size: 13, weight: .regular))
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .status:
            Text(message.text)
                .font(CodaDesignTokens.Typography.font(size: 11, weight: .medium))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CodaDesignTokens.Colors.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
        }
    }

    private var quickPromptStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(quickPrompts, id: \.self) { chip in
                    Button {
                        sendPrompt(chip)
                    } label: {
                        Text(chip)
                            .font(CodaDesignTokens.Typography.font(size: 11, weight: .semibold))
                            .foregroundStyle(CodaDesignTokens.Colors.primaryInk.opacity(0.88))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask coda or Scribble…", text: $promptDraft)
                .font(CodaDesignTokens.Typography.font(size: 13, weight: .medium))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                .onSubmit { submitDraft() }
                .accessibilityIdentifier("sidekick.input")

            if store.sidekick.isStreaming {
                Button {
                    store.sidekick.cancelStreaming()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.danger)
                        .frame(width: 36, height: 36)
                        .background(CodaDesignTokens.Colors.danger.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                }
                .accessibilityLabel("Stop streaming")
                .accessibilityIdentifier("sidekick.stop")
            } else {
                Button {
                    submitDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? CodaDesignTokens.Colors.mutedInk : Color.black)
                        .frame(width: 36, height: 36)
                        .background(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.white.opacity(0.06) : CodaDesignTokens.Colors.sidekickAccent,
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                }
                .accessibilityLabel("Send prompt")
                .accessibilityIdentifier("sidekick.send")
            }
        }
    }

    private func submitDraft() {
        let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        promptDraft = ""
        sendPrompt(trimmed)
    }

    private func sendPrompt(_ text: String) {
        store.sendSidekickPrompt(text)
    }
}
