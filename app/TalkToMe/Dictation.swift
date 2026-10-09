import AppKit
import Observation

/// Ties the hotkey, recorder and engines together. Everything here runs on
/// the main actor; only the network call and Apple's analyzer suspend.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable { case idle, recording, transcribing, done(text: String, engine: String), failed(String) }

    struct Entry: Identifiable {
        let id = UUID()
        let text: String
        let engine: String
        let seconds: Double
        var date = Date()
    }

    private(set) var phase: Phase = .idle {
        didSet {
            EventLog.write("phase \(Self.describe(phase))")
            onPhaseChange?(phase)
        }
    }
    /// Recent input levels, oldest first, for the waveform.
    private(set) var levels = [Float](repeating: 0, count: Dictation.levelCount)
    /// Whether sound is coming in. AirPods take up to a second after the key
    /// press; the pill says so meanwhile.
    private(set) var micLive = false
    private(set) var recordingStartedAt: Date?
    private(set) var remoteReachable = false
    private(set) var history: [Entry] = []
    private(set) var hotkeyActive = false
    enum HotkeyRepair: Equatable { case none, repairing, waitingForGrant, needsRelaunch, failed }
    /// Progress of `fixHotkeyPermission`.
    private(set) var hotkeyRepair = HotkeyRepair.none
    private(set) var stats = Stats.load()

    let settings: AppSettings
    static let levelCount = 28
    var onPhaseChange: ((Phase) -> Void)?

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var pressedAt = Date()
    /// Counts recordings, so a late callback from an earlier one is ignored.
    private var take = 0

    init(settings: AppSettings, live: Bool = true) {
        self.settings = settings
        guard live else { return }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.push(level) }
        }
        hotkey.key = { [settings] in MainActor.assumeIsolated { settings.hotkey } }
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        startHotkey()
        watchRemote()
    }

    func startHotkey() {
        if !HotkeyMonitor.hasPermission { HotkeyMonitor.requestPermission() }
        hotkeyActive = hotkey.start()
    }

    /// When the panel opens. A tap made before the grant never gets other
    /// apps' keys, so a grant that arrived after this launch needs a relaunch.
    /// macOS offers Quit & Reopen when it is granted; this covers Later.
    func refreshHotkeyPermission() {
        guard !hotkeyActive, hotkeyRepair != .repairing, HotkeyMonitor.hasPermission else { return }
        hotkeyRepair = .needsRelaunch
    }

    /// For answers left over from an earlier build, which macOS keeps
    /// applying (as "denied") to this one: clears them, so macOS asks again
    /// and lists TalkToMe, switched off. It asks for pasting at the same time,
    /// since the reset clears that too and it would otherwise ask again at
    /// the first paste.
    func fixHotkeyPermission() {
        hotkeyRepair = .repairing
        Task {
            let reset = await Task.detached { HotkeyMonitor.resetPermissions() }.value
            EventLog.write("hotkey permissions reset: \(reset)")
            guard reset else {
                hotkeyRepair = .failed
                return
            }
            HotkeyMonitor.requestPermission()
            if settings.autoPaste { _ = Self.canPaste(asking: true) }
            hotkeyRepair = .waitingForGrant
        }
    }

    /// Opens the app again once this process has exited (giving up after
    /// 10 s). Plain `open` only brings an already running copy forward, so
    /// this can never start a second one.
    func relaunch() {
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = [
            "-c",
            "for _ in $(seq 100); do kill -0 \"$1\" 2>/dev/null || break; sleep 0.1; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try helper.run()
        } catch {
            EventLog.write("relaunch failed: \(error)")
            return
        }
        EventLog.write("relaunching")
        EventLog.flush()
        NSApp.terminate(nil)
    }

    func copy(_ entry: Entry) {
        Self.putOnPasteboard(entry.text)
    }

    // MARK: - Engines

    var remote: RemoteTranscriber? {
        guard settings.engine == .remote, let url = settings.remoteBaseURL else { return nil }
        return RemoteTranscriber(baseURL: url, apiKey: settings.remoteAPIKey, model: settings.remoteModel)
    }

    var apple: AppleTranscriber { AppleTranscriber(localeID: settings.appleLocale) }

    /// One line for the UI: which engine the next dictation will use.
    var engineStatus: (text: String, healthy: Bool) {
        switch settings.engine {
        case .apple:
            return ("On-device", true)
        case .remote:
            guard let remote else { return ("Set up server", false) }
            if remoteReachable { return (remote.name, true) }
            return (settings.fallbackToApple ? "Offline · Apple" : "Offline", false)
        }
    }

    /// The configured remote first; Apple when it is unreachable or fails,
    /// if the user allows the fallback.
    func run(_ pcm: Data) async throws -> (text: String, engine: String) {
        guard settings.engine == .remote else {
            return (try await apple.transcribe(pcm), apple.name)
        }
        guard let remote else {
            if settings.fallbackToApple { return (try await apple.transcribe(pcm), apple.name) }
            throw TranscriberError.badURL
        }
        if remoteReachable || !settings.fallbackToApple {
            do {
                return (try await remote.transcribe(pcm), remote.name)
            } catch {
                // Status only: a server's error body could echo request text.
                if case .server(let code, _) = error as? TranscriberError {
                    EventLog.write("remote failed: HTTP \(code)")
                } else {
                    EventLog.write("remote failed: \(error.localizedDescription)")
                }
                guard settings.fallbackToApple else { throw error }
                remoteReachable = false
            }
        }
        return (try await apple.transcribe(pcm), apple.name)
    }

    // MARK: - Flow

    private func handle(_ event: HotkeyStateMachine.Event) {
        switch event {
        case .start: begin()
        case .stop: finish()
        case .cancel: cancel()
        }
    }

    private func begin() {
        guard phase != .recording, phase != .transcribing else {
            EventLog.write("begin ignored, phase \(Self.describe(phase))")
            return
        }
        guard AudioRecorder.permission == .authorized else {
            Task { _ = await AudioRecorder.requestPermission() }
            fail("Microphone access needed")
            return
        }
        levels = [Float](repeating: 0, count: Self.levelCount)
        micLive = false
        recordingStartedAt = nil
        pressedAt = Date()
        take += 1
        let current = take
        // The pill shows at once; the start sound waits for the mic.
        phase = .recording
        let preferredUID = settings.microphoneUID
        Task { [weak self, recorder] in
            do {
                try await recorder.start(preferredUID: preferredUID) {
                    Task { @MainActor in self?.soundArrived(take: current) }
                }
            } catch {
                guard let self, take == current else { return }
                fail("Mic: \(error.localizedDescription)")
            }
        }
    }

    private func soundArrived(take: Int) {
        guard take == self.take, phase == .recording else { return }
        EventLog.write("mic live after \(Int(Date().timeIntervalSince(pressedAt) * 1000)) ms")
        micLive = true
        recordingStartedAt = Date()
        NSSound(named: "Tink")?.play()
    }

    private func cancel() {
        guard phase == .recording else { return }
        phase = .idle
        Task { _ = await recorder.stop() }
    }

    private func finish() {
        guard phase == .recording else {
            EventLog.write("finish ignored, phase \(Self.describe(phase))")
            return
        }
        guard micLive else {
            // Let go before the mic delivered any sound: there is nothing to
            // send. Say why, unless it was only a tap.
            let held = Date().timeIntervalSince(pressedAt)
            EventLog.write("released before the mic was live, after \(Int(held * 1000)) ms")
            if held < 0.3 {
                phase = .idle
            } else {
                fail("The microphone was still starting. Hold the key until you hear the sound.")
            }
            Task { _ = await recorder.stop() }
            return
        }
        phase = .transcribing
        Task {
            let pcm = await recorder.stop()
            let seconds = Double(pcm.count / 2) / AudioRecorder.sampleRate
            // Under a quarter second is an accidental press, not speech.
            guard seconds >= 0.25 else {
                EventLog.write("clip too short: \(seconds)s")
                phase = .idle
                return
            }
            NSSound(named: "Pop")?.play()
            await transcribe(pcm, seconds: seconds)
        }
    }

    private func transcribe(_ pcm: Data, seconds: Double) async {
        do {
            let started = Date()
            let (text, engine) = try await run(pcm)
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            guard !text.isEmpty else {
                fail("Didn't catch that. Is the right microphone selected?")
                return
            }
            history.insert(Entry(text: text, engine: engine, seconds: seconds), at: 0)
            history = Array(history.prefix(20))
            stats.record(text: text, seconds: seconds, latencyMs: latencyMs)
            stats.save()
            Self.putOnPasteboard(text)
            if settings.autoPaste { Self.paste() }
            show(.done(text: text, engine: engine), for: .seconds(2.2))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func describe(_ phase: Phase) -> String {
        switch phase {
        case .done(let text, let engine): "done(\(text.count) chars via \(engine))"
        case .failed(let message): "failed(\(message))"
        default: "\(phase)"
        }
    }

    private func push(_ level: Float) {
        guard phase == .recording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func fail(_ message: String) {
        show(.failed(message), for: .seconds(3.5))
    }

    /// Shows a transient phase, then returns to idle unless something newer
    /// (a fresh recording) has replaced it in the meantime.
    private func show(_ transient: Phase, for duration: Duration) {
        phase = transient
        Task {
            try? await Task.sleep(for: duration)
            if phase == transient { phase = .idle }
        }
    }

    /// Fills the model with sample data for design snapshots (--snapshot).
    func loadPreview(phase: Phase, history: [Entry], stats: Stats, remoteReachable: Bool, levels: [Float], micLive: Bool = true) {
        self.history = history
        self.hotkeyActive = true
        self.stats = stats
        self.remoteReachable = remoteReachable
        self.levels = levels
        self.micLive = micLive
        self.recordingStartedAt = micLive ? Date().addingTimeInterval(-7) : nil
        self.phase = phase
    }

    /// Shows the hotkey's permission warning in a given repair step (--snapshot).
    func loadPermissionPreview(_ repair: HotkeyRepair) {
        hotkeyActive = false
        hotkeyRepair = repair
    }

    // MARK: - Reachability

    func refreshRemote() async {
        remoteReachable = await remote?.isReachable() ?? false
    }

    private func watchRemote() {
        // Probe at launch, on wake (the network comes back) and every 30 s, so
        // the first dictation after opening the lid already knows where to go.
        Task { await refreshRemote() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshRemote()
            }
        }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshRemote()
            }
        }
    }

    // MARK: - Output

    private static func putOnPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether TalkToMe may paste (Accessibility). `asking` shows macOS's
    /// prompt and lists TalkToMe in System Settings if it is not allowed yet.
    private static func canPaste(asking: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): asking] as CFDictionary)
    }

    /// Sends ⌘V to the frontmost app. Needs Accessibility permission.
    private static func paste() {
        guard canPaste(asking: true) else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
