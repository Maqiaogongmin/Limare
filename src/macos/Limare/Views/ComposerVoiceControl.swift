import SwiftUI
import AppKit

fileprivate enum VoiceVisualPhase: Equatable {
    case idle
    case recording
    case transcribing
}

private enum VoiceButtonTokens {
    static let activeFill = dynamicAlpha(
        light: NSColor.white.withAlphaComponent(0.90),
        dark: NSColor.white.withAlphaComponent(0.11)
    )
    static let activeStroke = dynamicAlpha(
        light: NSColor.black.withAlphaComponent(0.10),
        dark: NSColor.white.withAlphaComponent(0.12)
    )
    static let activeHoverWash = dynamicAlpha(
        light: NSColor.black.withAlphaComponent(0.03),
        dark: NSColor.white.withAlphaComponent(0.04)
    )

    private static func dynamicAlpha(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Click-to-toggle voice dictation control inspired by transitions.dev (`c85AR0dBjUE`):
/// click once to enter the listening wave state, click again to finish and transcribe.
struct ComposerVoiceControl: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    private var isDictatingHere: Bool {
        appState.voiceInput.isTarget(window.chat) && appState.voiceInput.state.isActive
    }

    private var visualPhase: VoiceVisualPhase {
        guard isDictatingHere else { return .idle }
        if appState.voiceInput.state.isRecording { return .recording }
        if appState.voiceInput.state.isTranscribing { return .transcribing }
        return .idle
    }

    var body: some View {
        Button {
            switch visualPhase {
            case .idle:
                guard !isDictatingHere else { return }
                appState.voiceInput.setChatStore(window.chat)
                appState.voiceInput.start()
            case .recording:
                appState.voiceInput.finish()
            case .transcribing:
                break
            }
        } label: {
            ZStack {
                switch visualPhase {
                case .idle:
                    Image(systemName: "mic")
                        .font(.system(size: 14))
                        .transition(.opacity)
                case .recording:
                    VoiceListeningWaveGlyph()
                        .transition(.opacity)
                case .transcribing:
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.78)
                        .transition(.opacity)
                }
            }
            .animation(AppMotion.resolved(AppMotion.standard), value: visualPhase)
        }
        .buttonStyle(VoiceMicButtonStyle(phase: visualPhase))
        .disabled(isDictatingHere && !appState.voiceInput.state.isRecording)
        .help(helpText)
        .accessibilityLabel("Microphone")
        .accessibilityValue(accessibilityStatus)
        .onExitCommand {
            if visualPhase == .recording {
                appState.voiceInput.cancel()
            }
        }
    }

    private var helpText: LocalizedStringKey {
        switch visualPhase {
        case .idle: "Voice input (dictation)"
        case .recording: "Listening… Click to finish and transcribe"
        case .transcribing: "Transcribing…"
        }
    }

    private var accessibilityStatus: String {
        switch visualPhase {
        case .idle: ""
        case .recording: String(localized: "Listening…")
        case .transcribing: String(localized: "Transcribing…")
        }
    }
}

private struct VoiceMicButtonStyle: ButtonStyle {
    let phase: VoiceVisualPhase

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, phase: phase)
    }

    private struct BodyView: View {
        let configuration: ButtonStyleConfiguration
        let phase: VoiceVisualPhase
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var pressAnimation: Animation? {
            AppMotion.resolved(.timingCurve(0.22, 1, 0.36, 1, duration: 0.15))
        }

        var body: some View {
            configuration.label
                .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                .background {
                    switch phase {
                    case .idle:
                        RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            .fill((isHovering && isEnabled) || configuration.isPressed ? AppColors.ghostHover : .clear)
                    case .recording, .transcribing:
                        ZStack {
                            if phase == .recording {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.22))
                                    .blur(radius: 4)
                            }
                            Circle()
                                .fill(VoiceButtonTokens.activeFill)
                                .overlay(
                                    Circle()
                                        .fill(isHovering && isEnabled ? VoiceButtonTokens.activeHoverWash : .clear)
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(VoiceButtonTokens.activeStroke, lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.08), radius: 2.5, x: 0, y: 1)
                        }
                    }
                }
                .contentShape(
                    phase == .idle
                        ? AnyShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                        : AnyShape(Circle())
                )
                .foregroundStyle(
                    phase == .idle
                        ? (isHovering && isEnabled ? AppColors.textPrimary : AppColors.ghostIdle)
                        : AppColors.textPrimary
                )
                .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1.0)
                .opacity(phase == .idle && !isEnabled ? 0.45 : 1.0)
                .onHover { isHovering = $0 }
                .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
                .animation(pressAnimation, value: configuration.isPressed)
                .animation(AppMotion.resolved(AppMotion.standard), value: phase)
        }
    }
}

private struct VoiceListeningWaveGlyph: View {
    private static let baseHeights: [CGFloat] = [4.5, 9.0, 13.5, 9.0, 4.5]
    private static let phaseOffsets: [Double] = [0.0, -0.30, -0.60, -0.15, -0.45]
    private static let period: Double = 0.9
    private static let minScaleY: Double = 0.35

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let count = Self.baseHeights.count
                let barWidth: CGFloat = 1.75
                let spacing: CGFloat = 1.75
                let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let midY = size.height / 2

                for index in 0..<count {
                    let scaleY: Double
                    if reduceMotion {
                        scaleY = 1.0
                    } else {
                        let phase = (elapsed / Self.period) + Self.phaseOffsets[index]
                        let unit = 0.5 * (1.0 + cos(2.0 * .pi * phase))
                        scaleY = Self.minScaleY + (1.0 - Self.minScaleY) * unit
                    }
                    let barHeight = Self.baseHeights[index] * CGFloat(scaleY)
                    let x = startX + CGFloat(index) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(AppColors.textPrimary)
                    )
                }
            }
            .frame(width: 16, height: 14)
        }
        .accessibilityHidden(true)
    }
}

/// A voice input or read-aloud failure, beside the control that failed: one line, the full text
/// on hover, an optional fix action and a dismiss button.
struct VoiceErrorCapsule: View {
    let message: String
    var actionTitle: LocalizedStringKey? = nil
    var onAction: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .help(message)
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .font(.caption2.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppColors.statusWarning.opacity(0.1))
        .clipShape(Capsule())
    }
}
