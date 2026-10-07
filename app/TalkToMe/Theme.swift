import SwiftUI

/// Near-black surfaces and one blue-violet accent (Superwhisper), with
/// Oura's quiet tiles and muted state colours.
enum Palette {
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let card = Color.white.opacity(0.05)
    static let cardHover = Color.white.opacity(0.085)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color(red: 0.96, green: 0.96, blue: 0.98)
    static let muted = Color(red: 0.55, green: 0.58, blue: 0.64)
    static let faint = Color(red: 0.38, green: 0.40, blue: 0.45)
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let accent2 = Color(red: 0.66, green: 0.50, blue: 1.0)
    static let success = Color(red: 0.50, green: 0.82, blue: 0.63)
    static let warning = Color(red: 0.92, green: 0.70, blue: 0.38)
}

/// One typeface everywhere: SF Pro. Hierarchy comes from size, weight and
/// colour, never from mixing families.
enum Typeface {
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Large figures for the stat tiles: light, tight, tabular.
    static func figure(_ size: CGFloat) -> Font {
        .system(size: size, weight: .light).monospacedDigit()
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: 3)
    }
}
