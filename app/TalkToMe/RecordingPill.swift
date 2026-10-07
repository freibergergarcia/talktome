import AppKit
import SwiftUI

// MARK: - Panel

/// A borderless panel that floats over everything, on every Space, and never
/// takes focus, so the app you are dictating into stays frontmost.
@MainActor
final class PillPanel {
    private let panel: NSPanel
    private let size = NSSize(width: 420, height: 160)

    init(dictation: Dictation) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: PillView(dictation: dictation))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        dictation.onPhaseChange = { [weak self] phase in self?.update(phase) }
    }

    private func update(_ phase: Dictation.Phase) {
        if phase == .idle {
            // Let the SwiftUI exit animation play before the window goes away.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !self.isShowingContent { self.panel.orderOut(nil) }
            }
            isShowingContent = false
            return
        }
        isShowingContent = true
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
    }

    private var isShowingContent = false

    /// Bottom centre of the screen the mouse is on, clear of the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
    }
}

// MARK: - View

/// Superwhisper-style: a small black capsule where the waveform is the
/// whole story. Text appears only when there is something to read.
struct PillView: View {
    let dictation: Dictation

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if dictation.phase != .idle {
                pill
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.95, anchor: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: dictation.phase)
    }

    private var isCompact: Bool {
        dictation.phase == .recording || dictation.phase == .transcribing
    }

    private var pill: some View {
        content
            .padding(.horizontal, isCompact ? 18 : 20)
            .padding(.vertical, isCompact ? 12 : 16)
            .frame(width: isCompact ? 250 : 380)
            .background(background)
            .clipShape(.rect(cornerRadius: isCompact ? 30 : 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isCompact ? 30 : 24, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    /// Near-black with one soft glow in the state's colour.
    private var background: some View {
        ZStack {
            Palette.ink
            RadialGradient(colors: [accent.opacity(0.35), .clear],
                           center: .init(x: 0.5, y: 1.3), startRadius: 0, endRadius: 200)
                .animation(.easeInOut(duration: 0.5), value: accent)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dictation.phase {
        case .recording:
            HStack(spacing: 14) {
                PulsingDot(color: Palette.accent)
                Waveform(levels: dictation.levels)
                    .frame(height: 40)
                Elapsed(since: dictation.recordingStartedAt ?? .now)
            }
        case .transcribing:
            HStack(spacing: 14) {
                PulsingDot(color: Palette.accent2)
                Shimmer()
                    .frame(height: 40)
                Text("…")
                    .font(Typeface.ui(15, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 38, alignment: .trailing)
            }
        case .done(let text, let engine):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.success)
                    Text(dictation.settings.autoPaste ? "Pasted" : "Copied")
                        .font(Typeface.ui(12, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Text(engine)
                        .font(Typeface.ui(11))
                        .foregroundStyle(Palette.faint)
                }
                Text(text)
                    .font(Typeface.ui(14))
                    .foregroundStyle(Palette.text.opacity(0.88))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Palette.warning)
                Text(message)
                    .font(Typeface.ui(13))
                    .foregroundStyle(Palette.text.opacity(0.88))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .idle:
            EmptyView()
        }
    }

    private var accent: Color {
        switch dictation.phase {
        case .recording: Palette.accent
        case .transcribing: Palette.accent2
        case .done: Palette.success
        case .failed: Palette.warning
        case .idle: .clear
        }
    }
}

// MARK: - Pieces

/// Bars mirrored around the centre line, newest on the right, fading in
/// from the left so the eye lands on "now".
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(levels.indices, id: \.self) { i in
                    let fade: Double = 0.25 + 0.75 * Double(i) / Double(max(levels.count - 1, 1))
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                             startPoint: .bottom, endPoint: .top))
                        .opacity(fade)
                        .frame(width: 3, height: max(3, geo.size.height * CGFloat(levels[i])))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeOut(duration: 0.07), value: levels)
    }
}

/// Idle bars rippling while the engine works.
struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(spacing: 2.5) {
                    ForEach(0..<Dictation.levelCount, id: \.self) { i in
                        let wave: Double = 0.5 + 0.5 * sin(t * 6 - Double(i) * 0.45)
                        Capsule()
                            .fill(Palette.accent2.opacity(0.35 + 0.5 * wave))
                            .frame(width: 3, height: 3 + geo.size.height * 0.35 * wave)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

struct PulsingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let pulse: Double = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.4 + 0.5 * pulse), radius: 3 + 4 * pulse)
        }
    }
}

struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(Typeface.ui(15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
