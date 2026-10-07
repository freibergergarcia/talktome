import Foundation
import Observation
import ServiceManagement

/// Everything the user can configure. Plain values live in UserDefaults;
/// the remote API key lives in the Keychain.
@MainActor
@Observable
final class AppSettings {
    enum Engine: String, CaseIterable, Identifiable {
        /// Apple's on-device SpeechTranscriber. Works with no setup.
        case apple
        /// Any server speaking OpenAI's /v1/audio/transcriptions, including
        /// talktome-server.
        case remote

        var id: String { rawValue }
    }

    var engine: Engine { didSet { save(engine.rawValue, "engine") } }
    /// Use Apple when the remote server is unreachable or fails.
    var fallbackToApple: Bool { didSet { save(fallbackToApple, "fallbackToApple") } }
    /// Base URL ending in /v1, e.g. http://my-mac.local:8766/v1
    var remoteURL: String { didSet { save(remoteURL, "remoteURL") } }
    /// Sent as the `model` field; talktome-server ignores it, hosted APIs need it.
    var remoteModel: String { didSet { save(remoteModel, "remoteModel") } }
    var appleLocale: String { didSet { save(appleLocale, "appleLocale") } }
    /// Core Audio UID of the chosen microphone, nil for automatic.
    var microphoneUID: String? { didSet { save(microphoneUID, "microphoneUID") } }
    var hotkey: HotkeyKey { didSet { save(hotkey.rawValue, "hotkey") } }
    var autoPaste: Bool { didSet { save(autoPaste, "autoPaste") } }
    /// Dock icon (with the running dot) for as long as the app runs. Off makes
    /// it a menu bar–only app that shows in the Dock just while Settings is open.
    var showInDock: Bool {
        didSet {
            save(showInDock, "showInDock")
            onShowInDockChange?()
        }
    }
    var onShowInDockChange: (() -> Void)?
    var debugLogging: Bool {
        didSet {
            save(debugLogging, "debugLogging")
            EventLog.enabled = debugLogging
        }
    }

    var remoteAPIKey: String {
        didSet { if usesKeychain { Keychain.write(remoteAPIKey, account: Self.apiKeyAccount) } }
    }

    var remoteBaseURL: URL? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }

    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                EventLog.write("launch at login: \(error.localizedDescription)")
            }
        }
    }

    private static let apiKeyAccount = "remote-api-key"
    private let defaults: UserDefaults
    private let usesKeychain: Bool

    /// `usesKeychain: false` keeps the API key in memory only, for snapshots
    /// that must neither read nor overwrite the real one.
    init(defaults: UserDefaults = .standard, usesKeychain: Bool = true) {
        self.defaults = defaults
        self.usesKeychain = usesKeychain
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .apple
        fallbackToApple = Self.bool(defaults, "fallbackToApple", default: true)
        remoteURL = defaults.string(forKey: "remoteURL") ?? ""
        remoteModel = defaults.string(forKey: "remoteModel") ?? "whisper-1"
        appleLocale = defaults.string(forKey: "appleLocale") ?? Locale.current.identifier(.bcp47)
        microphoneUID = defaults.string(forKey: "microphoneUID")
        hotkey = HotkeyKey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightCommand
        autoPaste = Self.bool(defaults, "autoPaste", default: true)
        showInDock = Self.bool(defaults, "showInDock", default: true)
        debugLogging = defaults.bool(forKey: "debugLogging")
        remoteAPIKey = usesKeychain ? Keychain.read(account: Self.apiKeyAccount) ?? "" : ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        EventLog.enabled = debugLogging
    }

    /// `bool(forKey:)` understands "YES"/"NO"/"1"/"0" strings too, which is
    /// how values passed as launch arguments (`-autoPaste NO`) arrive.
    private static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
