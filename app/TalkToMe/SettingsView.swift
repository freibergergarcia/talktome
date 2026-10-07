import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let dictation: Dictation

    @State private var locales: [Locale] = []
    @State private var microphones = Microphones.inputs()
    @State private var testResult: TestResult?
    @State private var testing = false

    /// Set by snapshot mode so screenshots never show the real device name.
    static var microphoneOverride: String?

    enum TestResult {
        case ok(String), failed(String)
    }

    var body: some View {
        Form {
            general
            transcription
            microphone
            advanced
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { locales = await AppleTranscriber.supportedLocales() }
        .onChange(of: settings.remoteURL) { Task { await dictation.refreshRemote() } }
        .onChange(of: settings.engine) { Task { await dictation.refreshRemote() } }
    }

    // MARK: - Sections

    private var general: some View {
        Section {
            Picker("Dictation key", selection: $settings.hotkey) {
                ForEach(HotkeyKey.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Paste at the cursor", isOn: $settings.autoPaste)
            Toggle("Open at login", isOn: $settings.launchAtLogin)
            Toggle("Show in Dock", isOn: $settings.showInDock)
        } header: {
            Text("General")
        } footer: {
            Text("Tap the key to start and stop, or hold it while you talk. Esc cancels. "
                 + "Every transcript is also copied to the clipboard.")
                .settingsFootnote()
        }
    }

    private var transcription: some View {
        Section {
            Picker("Engine", selection: $settings.engine) {
                Text("On this Mac").tag(AppSettings.Engine.apple)
                Text("Server").tag(AppSettings.Engine.remote)
            }
            .pickerStyle(.segmented)

            if settings.engine == .remote {
                TextField("Server URL", text: $settings.remoteURL, prompt: Text("http://my-mac.local:8766/v1"))
                SecureField("API key or token", text: $settings.remoteAPIKey, prompt: Text("Optional"))
                TextField("Model", text: $settings.remoteModel, prompt: Text("whisper-1"))
                Toggle("Use this Mac when the server is unreachable", isOn: $settings.fallbackToApple)
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(testing || settings.remoteBaseURL == nil)
                    Spacer()
                    testLabel
                }
            }

            Picker("Language on this Mac", selection: $settings.appleLocale) {
                if !locales.contains(where: { $0.identifier(.bcp47) == settings.appleLocale }) {
                    Text(settings.appleLocale).tag(settings.appleLocale)
                }
                ForEach(locales, id: \.self) { locale in
                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        .tag(locale.identifier(.bcp47))
                }
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text(settings.engine == .remote
                 ? "Any server with an OpenAI-compatible /v1/audio/transcriptions endpoint works, including "
                   + "talktome-server. Audio goes only to the URL above."
                 : "Apple's on-device model. Nothing leaves this Mac. It transcribes one language at a time.")
                .settingsFootnote()
        }
    }

    private var microphone: some View {
        Section {
            Picker("Input", selection: $settings.microphoneUID) {
                Text("Automatic (\(Self.microphoneOverride ?? Microphones.resolve(preferredUID: nil)?.name ?? "none"))").tag(String?.none)
                ForEach(microphones) { mic in
                    Text(mic.isBuiltIn && Microphones.lidClosed ? "\(mic.name) (lid closed)" : mic.name)
                        .tag(String?.some(mic.uid))
                }
            }
            .onAppear { microphones = Microphones.inputs() }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Automatic uses the system input, but skips the built-in mic while the lid is closed.")
                .settingsFootnote()
        }
    }

    private var advanced: some View {
        Section {
            Toggle("Debug log", isOn: $settings.debugLogging)
            if settings.debugLogging {
                Button("Show log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([EventLog.url]) }
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Logs key presses, timings and errors to ~/Library/Logs/TalkToMe.log. Never what you said.")
                .settingsFootnote()
        }
    }

    // MARK: - Connection test

    @ViewBuilder
    private var testLabel: some View {
        switch testResult {
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    /// Sends half a second of silence: proves the URL, the endpoint and the
    /// key in one request without transcribing anything real.
    private func test() async {
        guard let url = settings.remoteBaseURL else { return }
        testing = true
        defer { testing = false }
        let remote = RemoteTranscriber(baseURL: url, apiKey: settings.remoteAPIKey, model: settings.remoteModel)
        let silence = Data(count: Int(AudioRecorder.sampleRate) / 2 * 2)
        let started = Date()
        do {
            _ = try await remote.transcribe(silence)
            testResult = .ok("Connected · \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch TranscriberError.server(401, _) {
            testResult = .failed("Wrong or missing API key")
        } catch {
            testResult = .failed(error.localizedDescription)
        }
        await dictation.refreshRemote()
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
