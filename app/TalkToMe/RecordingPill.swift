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

/// Superwhisper-style: a small glass capsule where the waveform is the
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
            .glassEffect(.regular, in: .rect(cornerRadius: isCompact ? 30 : 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isCompact ? 30 : 24, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    /// Liquid Glass darkened toward ink, so the lines read over any app,
    /// with one soft glow in the state's colour.
    private var background: some View {
        ZStack {
            Palette.ink.opacity(0.6)
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
                PulsingDot(color: dictation.micLive ? Palette.accent : Palette.muted)
                ZStack {
                    Waveform(levels: dictation.levels)
                        .opacity(dictation.micLive ? 1 : 0)
                    if !dictation.micLive { StartingHint() }
                }
                .frame(height: 40)
                Elapsed(since: dictation.recordingStartedAt ?? .now)
                    .opacity(dictation.micLive ? 1 : 0)
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

/// The voice as flowing lines: three soft waves under a bell-shaped
/// envelope, still at the ends and alive in the middle. They always drift;
/// how tall they swell follows the voice.
struct Waveform: View {
    let levels: [Float]

    /// The louder of the last two levels (0.2 s), so the wave rises on
    /// each syllable instead of averaging it away.
    private var loudness: CGFloat {
        CGFloat(levels.suffix(2).max() ?? 0)
    }

    var body: some View {
        // The curve lifts normal speech (levels around 0.4 to 0.7) to most
        // of the height; silence keeps a small ripple.
        LiquidWave(amplitude: 0.1 + 0.9 * pow(loudness, 0.6), colors: [Palette.accent, Palette.accent2])
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: loudness)
    }
}

/// The engine at work: the same lines, calm and in the second accent.
struct Shimmer: View {
    var body: some View {
        LiquidWave(amplitude: 0.35, colors: [Palette.accent2, Palette.accent2.opacity(0.6)], speed: 2.4)
    }
}

/// Layered sine lines with a soft glow. `amplitude` is 0…1 of half the height.
struct LiquidWave: View {
    var amplitude: CGFloat
    var colors: [Color]
    /// Drift in radians per second.
    var speed = 3.2

    /// Each strand: cycles across the width, drift rate, height and opacity.
    private static let strands: [(cycles: Double, drift: Double, height: CGFloat, opacity: Double, width: CGFloat)] = [
        (1.6, 1.0, 1.0, 1.0, 2.2),
        (2.3, -0.7, 0.65, 0.55, 1.4),
        (1.1, 1.4, 0.4, 0.35, 1.2),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            ZStack {
                ForEach(Self.strands.indices, id: \.self) { i in
                    let strand = Self.strands[i]
                    WaveLine(amplitude: amplitude * strand.height, cycles: strand.cycles,
                             phase: t * speed * strand.drift + Double(i) * 2.1)
                        .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: strand.width, lineCap: .round, lineJoin: .round))
                        .opacity(strand.opacity)
                }
            }
            .shadow(color: colors[0].opacity(0.7), radius: 6)
        }
    }
}

/// One sine line, flat at both ends. Its amplitude animates; the phase is
/// set every frame.
struct WaveLine: Shape {
    var amplitude: CGFloat
    var cycles: Double
    var phase: Double

    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let steps = max(Int(rect.width / 2), 2)
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let envelope = pow(sin(.pi * x), 1.4)
            let y = mid - amplitude * (rect.height / 2 - 2) * envelope * sin(2 * .pi * cycles * x + phase)
            let point = CGPoint(x: rect.minX + rect.width * x, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// While the mic starts. It appears only after a moment, so a mic that
/// starts at once never flashes it.
struct StartingHint: View {
    @State private var visible = false

    var body: some View {
        Text("Starting mic…")
            .font(Typeface.ui(13, weight: .medium))
            .foregroundStyle(Palette.muted)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
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
