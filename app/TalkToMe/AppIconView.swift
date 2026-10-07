import SwiftUI

/// The app icon, drawn in code so it stays editable and on-brand.
/// `TalkToMe --icon <dir>` renders it to PNG; scripts/make-icon.sh turns that
/// into the asset catalog.
///
/// Liquid-glass look: a deep blue-violet squircle, and floating over it a
/// frosted glass capsule (the recording pill) with a waveform inside, light
/// catching its rim and a soft glow beneath.
struct AppIconView: View {
    /// Rendered at 1024 × 1024. The body follows Apple's macOS grid: an
    /// 824-point squircle centred on the canvas, leaving room for the shadow.
    var body: some View {
        ZStack {
            squircle
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }

    private let size: CGFloat = 824
    private let corner: CGFloat = 185

    private var squircle: some View {
        ZStack {
            background
            glowUnderPill
            pill
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay(
            // Glass edge on the tile itself: bright top, fading down.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.15)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 3
                )
        )
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.05, blue: 0.12)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [Palette.accent.opacity(0.85), .clear],
                           center: .init(x: 0.18, y: 0.12), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Palette.accent2.opacity(0.75), .clear],
                           center: .init(x: 0.92, y: 0.95), startRadius: 0, endRadius: 560)
        }
    }

    private var glowUnderPill: some View {
        Ellipse()
            .fill(Palette.accent2.opacity(0.55))
            .frame(width: 560, height: 220)
            .blur(radius: 70)
            .offset(y: 70)
    }

    private let pillSize = CGSize(width: 650, height: 320)

    /// Liquid glass: mostly clear, a thin bright rim, the background's colour
    /// bending in along the inner edge, and a soft specular sheen on top.
    private var pill: some View {
        let shape = Capsule(style: .continuous)
        return ZStack {
            // Clear-ish body with a faint frost.
            shape.fill(.white.opacity(0.07))
            // Refraction: violet and blue light gathering at the inner edge.
            shape
                .strokeBorder(
                    LinearGradient(colors: [Palette.accent.opacity(0.9), Palette.accent2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 46
                )
                .blur(radius: 26)
                .opacity(0.75)
            // Specular sheen across the upper half.
            Ellipse()
                .fill(Color(red: 0.88, green: 0.92, blue: 1.0).opacity(0.42))
                .frame(width: pillSize.width * 0.7, height: pillSize.height * 0.22)
                .blur(radius: 16)
                .offset(y: -pillSize.height * 0.34)
            waveform
        }
        .frame(width: pillSize.width, height: pillSize.height)
        .clipShape(shape)
        .overlay(
            // Rim light: bright top-left and bottom-right, dim in between.
            shape.strokeBorder(
                AngularGradient(
                    colors: [.white.opacity(0.95), .white.opacity(0.12), .white.opacity(0.7),
                             .white.opacity(0.12), .white.opacity(0.95)],
                    center: .center, angle: .degrees(200)
                ),
                lineWidth: 4
            )
        )
        .shadow(color: Color(red: 0.03, green: 0.02, blue: 0.10).opacity(0.6), radius: 34, y: 26)
        .offset(y: 10)
    }

    private var waveform: some View {
        // Few, bold bars so the shape still reads at 16 px.
        let heights: [CGFloat] = [0.30, 0.62, 0.92, 0.70, 1.0, 0.56, 0.84, 0.48, 0.26]
        return HStack(spacing: 26) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [.white, Color(red: 0.86, green: 0.84, blue: 1.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 34, height: 196 * heights[i])
                    .shadow(color: Palette.accent2.opacity(0.8), radius: 14)
            }
        }
    }
}
