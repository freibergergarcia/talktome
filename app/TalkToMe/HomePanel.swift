import SwiftUI

/// The menu bar window: status, today's numbers, recent dictations, settings.
struct HomePanel: View {
    let dictation: Dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            hero
            stats
            recent
            footer
        }
        .padding(18)
        .frame(width: 340)
        .background(backdrop)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            AppGlyph()
            Text("TalkToMe")
                .font(Typeface.ui(13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
            HStack(spacing: 6) {
                Dot(color: engineColor)
                Text(engineStatus)
                    .font(Typeface.ui(11, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.card, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(partOfDay), \(firstName)")
                .font(Typeface.ui(22, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Palette.text)
            if dictation.hotkeyActive {
                (Text("Tap ").foregroundStyle(Palette.muted)
                 + Text(dictation.settings.hotkey.symbol).foregroundStyle(Palette.text)
                 + Text(" to start and stop. Esc cancels.").foregroundStyle(Palette.muted))
                    .font(Typeface.ui(12.5))
            } else {
                Text(permissionHint)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch dictation.hotkeyRepair {
                    case .needsRelaunch:
                        Button("Relaunch") { dictation.relaunch() }
                        Button("Open Settings") { Self.openInputMonitoring() }
                    case .failed:
                        Button("Fix permission") { dictation.fixHotkeyPermission() }
                        Button("Open Settings") { Self.openInputMonitoring() }
                    case .none, .repairing:
                        Button("Try again") { dictation.startHotkey() }
                        Button("Fix permission") { dictation.fixHotkeyPermission() }
                            .disabled(dictation.hotkeyRepair == .repairing)
                    }
                }
                .buttonStyle(CapsuleButton())
                .padding(.top, 4)
            }
        }
    }

    private var permissionHint: String {
        let key = dictation.settings.hotkey.symbol
        let pane = HotkeyMonitor.permissionName
        return switch dictation.hotkeyRepair {
        case .needsRelaunch: "Turn on TalkToMe in \(pane), then relaunch."
        case .failed: "Could not reset the permission. In \(pane), remove TalkToMe with −, then add it again."
        case .none, .repairing: "Turn on TalkToMe in \(pane) so \(key) works in every app. Already on? After an update it can still point at the old version."
        }
    }

    private static func openInputMonitoring() {
        let pane = "x-apple.systempreferences:com.apple.preference.security"
        if !NSWorkspace.shared.open(URL(string: pane + "?Privacy_ListenEvent")!) {
            NSWorkspace.shared.open(URL(string: pane)!)
        }
    }

    private var stats: some View {
        let today = dictation.stats.today
        return HStack(spacing: 8) {
            Tile(label: "Words", value: today.words.formatted(), unit: nil)
            Tile(label: "Saved", value: dictation.stats.minutesSavedToday.formatted(.number.precision(.fractionLength(0))), unit: "min")
            Tile(label: "Latency", value: dictation.stats.lastLatencyMs.map { $0.formatted() } ?? "–", unit: "ms")
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Recent")
            if dictation.history.isEmpty {
                Text("Dictations from this session appear here. Click one to copy it again.")
                    .font(Typeface.ui(12))
                    .foregroundStyle(Palette.faint)
            } else {
                VStack(spacing: 4) {
                    ForEach(dictation.history.prefix(3)) { entry in
                        RecentRow(entry: entry) { dictation.copy(entry) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Settings…") { WindowRouter.shared?.showSettings() }
            .keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(Typeface.ui(11.5, weight: .medium))
        .foregroundStyle(Palette.muted)
    }

    /// Near-black with a blue-violet glow from the top, Superwhisper's sky.
    private var backdrop: some View {
        ZStack {
            Palette.ink
            RadialGradient(colors: [Palette.accent.opacity(0.28), .clear],
                           center: .init(x: 0.2, y: -0.1), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Palette.accent2.opacity(0.18), .clear],
                           center: .init(x: 1.0, y: 0.05), startRadius: 0, endRadius: 260)
        }
    }

    // MARK: - Copy

    private var engineStatus: String { dictation.engineStatus.text }

    private var engineColor: Color { dictation.engineStatus.healthy ? Palette.success : Palette.warning }

    private var partOfDay: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// Set by snapshot mode so screenshots never show the real user's name.
    static var nameOverride: String?

    private var firstName: String {
        if let name = Self.nameOverride { return name }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }
}

// MARK: - Components

struct AppGlyph: View {
    /// The app icon itself, scaled down, so the panel and Dock always match.
    var body: some View {
        AppIconView()
            .scaleEffect(26.0 / 1024)
            .frame(width: 26, height: 26)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.ui(11.5, weight: .semibold))
            .foregroundStyle(Palette.muted)
    }
}

/// Oura-style tile: small label, large light figure.
struct Tile: View {
    let label: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(Typeface.ui(11, weight: .medium))
                .foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Typeface.figure(26))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(Typeface.ui(11))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

struct RecentRow: View {
    let entry: Dictation.Entry
    let copy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Palette.text.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text("\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.engine)")
                        .foregroundStyle(Palette.faint)
                    Spacer()
                    if copied {
                        Text("Copied").foregroundStyle(Palette.success)
                    } else if hovering {
                        Text("Copy").foregroundStyle(Palette.muted)
                    }
                }
                .font(Typeface.ui(10.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovering ? Palette.cardHover : Palette.card, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title)
                .font(Typeface.ui(12))
                .foregroundStyle(Palette.text.opacity(0.85))
                .fixedSize()
            Spacer(minLength: 12)
            control
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180, alignment: .trailing)
                .tint(Palette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct CapsuleButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(12, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Palette.card, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
