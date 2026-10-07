import AVFoundation
import SwiftUI

@main
struct TalkToMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let dictation: Dictation?
    private let pill: PillPanel?
    private let router: WindowRouter?

    init() {
        let settings = AppSettings()
        if CommandLine.handled(settings: settings) { exit(0) }

        let dictation = Dictation(settings: settings)
        self.dictation = dictation
        pill = PillPanel(dictation: dictation)
        router = WindowRouter(dictation: dictation)
    }

    var body: some Scene {
        // The menu bar item, panel and Settings window are AppKit-managed in
        // WindowRouter; SwiftUI still needs one scene, so this one is hidden.
        MenuBarExtra("TalkToMe", isInserted: .constant(false)) { EmptyView() }
    }
}

// MARK: - Command line

/// Developer entry points; the app quits after running one.
///
///   TalkToMe --snapshot <dir>     render every screen to PNGs with sample data
///   TalkToMe --transcribe <file>  run the configured engine on an audio file
///   TalkToMe --icon <dir>         render the app icon to AppIcon.png
private extension CommandLine {
    @MainActor
    static func handled(settings: AppSettings) -> Bool {
        if let dir = value(after: "--icon") {
            Snapshots.renderIcon(to: URL(fileURLWithPath: dir))
            return true
        }
        if let dir = value(after: "--snapshot") {
            Snapshots.render(to: URL(fileURLWithPath: dir), settings: settings)
            return true
        }
        if let path = value(after: "--transcribe") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await transcribe(URL(fileURLWithPath: path), settings: settings)
                semaphore.signal()
            }
            // Spin the main run loop so main-actor work can proceed.
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return true
        }
        return false
    }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func transcribe(_ file: URL, settings: AppSettings) async {
        let dictation = Dictation(settings: settings, live: false)
        do {
            let pcm = try AudioRecorder.pcm16(contentsOf: file)
            await dictation.refreshRemote()
            let started = Date()
            let (text, engine) = try await dictation.run(pcm)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("[\(engine), \(ms) ms] \(text)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        }
    }
}

/// Renders screens with sample data, so the design can be reviewed without
/// driving the real hotkey (and produces the README screenshots).
@MainActor
enum Snapshots {
    static func render(to dir: URL, settings _: AppSettings) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Sample settings in a throwaway store: no real name, host or key.
        let suite = "dev.talktome.snapshots"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, usesKeychain: false)
        settings.engine = .remote
        settings.remoteURL = "http://studio.local:8766/v1"
        settings.remoteModel = "parakeet-tdt-0.6b-v3"
        settings.remoteAPIKey = "example-token"
        settings.appleLocale = "en-US"
        HomePanel.nameOverride = "Alex"

        var stats = Stats()
        stats.record(text: String(repeating: "word ", count: 1240), seconds: 420, latencyMs: 372)
        let now = Date()
        let history = [
            Dictation.Entry(text: "Can you take a look at the pull request before lunch? The login redirect is fixed.",
                            engine: "studio.local", seconds: 6, date: now.addingTimeInterval(-120)),
            Dictation.Entry(text: "Amanhã vou trabalhar de casa. Me mandem mensagem se precisarem de alguma coisa.",
                            engine: "studio.local", seconds: 7, date: now.addingTimeInterval(-1500)),
            Dictation.Entry(text: "Remind me to check the deploy logs after the standup.",
                            engine: "Apple", seconds: 3, date: now.addingTimeInterval(-5400)),
        ]
        // Split into typed steps: as one expression, older Swift compilers
        // (Xcode 26) time out type-checking it.
        let levels: [Float] = (0..<Dictation.levelCount).map { i in
            let position: Double = Double(i) / Double(Dictation.levelCount)
            let wave: Double = abs(sin(Double(i) * 0.55))
            let rise: Double = 0.4 + 0.6 * position
            return Float(0.2 + 0.75 * wave * rise)
        }

        let model = Dictation(settings: settings, live: false)
        model.loadPreview(phase: .idle, history: history, stats: stats, remoteReachable: true, levels: levels)
        save(HomePanel(dictation: model), "home", to: dir)
        save(SettingsView(settings: settings, dictation: model), "settings", to: dir)

        let phases: [(String, Dictation.Phase)] = [
            ("pill-recording", .recording),
            ("pill-transcribing", .transcribing),
            ("pill-done", .done(text: history[0].text, engine: "studio.local")),
            ("pill-failed", .failed("Didn't catch that. Is the right microphone selected?")),
        ]
        for (name, phase) in phases {
            let pillModel = Dictation(settings: settings, live: false)
            pillModel.loadPreview(phase: phase, history: [], stats: stats, remoteReachable: true, levels: levels)
            let view = PillView(dictation: pillModel)
                .frame(width: 420, height: 160)
                .background(Color(red: 0.22, green: 0.24, blue: 0.30))
            save(view, name, to: dir)
        }
    }

    static func renderIcon(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ImageRenderer, not the window path: the icon is pure SwiftUI and
        // needs blur, which cacheDisplay skips.
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "AppIcon.png"))
    }

    /// Draws through an offscreen window rather than ImageRenderer, which
    /// cannot render native AppKit controls (forms, pickers, switches).
    private static func save(_ view: some View, _ name: String, to dir: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}
