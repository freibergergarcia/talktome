import SwiftUI

/// The background of the installer disk image: the app on the left, an arrow,
/// Applications on the right. `TalkToMe --dmg-background <dir>` renders it;
/// scripts/make-dmg.sh places the icons over it.
///
/// Light on purpose: Finder draws the icon labels itself, in dark text in
/// light mode, and they must stay readable.
struct DMGBackgroundView: View {
    static let size = CGSize(width: 660, height: 400)
    /// Icon centres, shared with make-dmg.sh (which positions the Finder icons).
    static let appCenter = CGPoint(x: 180, y: 190)
    static let applicationsCenter = CGPoint(x: 480, y: 190)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.97, green: 0.97, blue: 1.0), Color(red: 0.92, green: 0.92, blue: 0.98)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.accent.opacity(0.16), .clear],
                           center: .init(x: 0.1, y: 0.0), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Palette.accent2.opacity(0.16), .clear],
                           center: .init(x: 0.95, y: 1.0), startRadius: 0, endRadius: 380)

            arrow
                .position(x: (Self.appCenter.x + Self.applicationsCenter.x) / 2, y: Self.appCenter.y - 10)

            Text("Drag TalkToMe to Applications to install")
                .font(Typeface.ui(13, weight: .medium))
                .foregroundStyle(Color(red: 0.35, green: 0.37, blue: 0.45))
                .position(x: Self.size.width / 2, y: 335)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                            startPoint: .leading, endPoint: .trailing))
    }
}
