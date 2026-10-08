import AppKit
import SwiftUI

/// Settings → Transcription → "Set up Parakeet on this Mac…".
struct LocalServerSheet: View {
    @Bindable var settings: AppSettings
    let dictation: Dictation

    @State private var server: LocalServer
    @State private var installed: InstalledAgent?
    /// Whether the installed server answers; nil until checked.
    @State private var answering: Bool?
    @State private var job: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    @MainActor init(settings: AppSettings, dictation: Dictation) {
        self.init(settings: settings, dictation: dictation, server: LocalServer(), installed: LocalServer.installed)
    }

    /// For snapshots: a server in a given state and a given existing install.
    init(settings: AppSettings, dictation: Dictation, server: LocalServer, installed: InstalledAgent?) {
        self.settings = settings
        self.dictation = dictation
        _server = State(initialValue: server)
        _installed = State(initialValue: installed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parakeet on this Mac").font(.title3.weight(.semibold))
            Text("Runs NVIDIA Parakeet here instead of on another Mac. Setup downloads about 2.6 GB "
                 + "(a private copy of Python, talktome-server and the model) and takes a few minutes. "
                 + "It needs about 2.9 GB of disk, and up to 4 GB of memory while transcribing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isWorking)
        .task(id: installed) {
            if let installed { answering = await LocalServer.isServing(installed.healthURL) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch server.state {
        case .idle:
            if let installed {
                Label(Self.describe(installed, answering: answering),
                      systemImage: answering == false ? "exclamationmark.circle" : "checkmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .working(let current, let download):
            steps(current: current, download: download)
        case .ready:
            steps(current: .ready, download: 1)
            Label("Ready. Dictation now uses Parakeet on this Mac.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func steps(current: SetupStep, download: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SetupStep.allCases.filter { $0 != .ready }, id: \.self) { step in
                HStack(spacing: 8) {
                    Group {
                        if step < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16)
                    Text(step.label)
                    if step == .model, step == current, let download {
                        ProgressView(value: download).frame(width: 140)
                        Text(Self.gigabytes(download)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .failed = server.state {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([LocalServer.setupLog]) }
            }
            if case .idle = server.state, installed != nil {
                Button("Remove", role: .destructive) { Task { await remove() } }
            }
            Spacer()
            switch server.state {
            case .idle:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let installed {
                    if installed.isLocalOnly && installed.port == 8766 {
                        Button("Update") { start() }
                    }
                    Button("Use It") { use(installed) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Set Up") { start() }.keyboardShortcut(.defaultAction)
                }
            case .working:
                Button("Cancel") { job?.cancel() }.keyboardShortcut(.cancelAction)
            case .ready:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { start() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isWorking: Bool {
        if case .working = server.state { return true }
        return false
    }

    private func start() {
        job = Task {
            await server.install()
            installed = LocalServer.installed
            if case .ready = server.state, let installed { use(installed, close: false) }
        }
    }

    private static func describe(_ agent: InstalledAgent, answering: Bool?) -> String {
        let network = agent.isLocalOnly ? "" : " It listens on the network (\(agent.host)); "
            + "update it the way you installed it (see server/README.md)."
        switch answering {
        case false?: return "talktome-server is installed on this Mac but not answering. "
            + "See ~/Library/Logs/talktome-server.log." + network
        default: return "talktome-server already runs on this Mac." + network
        }
    }

    private func remove() async {
        let localURL = installed?.baseURL
        await server.remove()
        installed = LocalServer.installed
        // Dictation would only fall back to Apple on every request.
        if installed == nil, settings.engine == .remote, settings.remoteURL == localURL { settings.engine = .apple }
        await dictation.refreshRemote()
    }

    private func use(_ agent: InstalledAgent, close: Bool = true) {
        settings.engine = .remote
        settings.remoteURL = agent.baseURL
        settings.remoteAPIKey = LocalServer.token
        Task { await dictation.refreshRemote() }
        if close { dismiss() }
    }

    private static func gigabytes(_ fraction: Double) -> String {
        let total = Double(ModelDownload.totalBytes) / 1e9
        return String(format: "%.1f of %.1f GB", fraction * total, total)
    }
}
