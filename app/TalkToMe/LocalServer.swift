import Foundation
import Observation

/// talktome-server on this Mac, set up from Settings in one click: runs the
/// bundled install-local-server.sh (a private Python, the server, a launch
/// agent on localhost), then waits while the server downloads the model and
/// starts.
@MainActor
@Observable
final class LocalServer {
    enum State: Equatable {
        case idle
        case working(SetupStep, download: Double?)
        case ready
        case failed(String)
    }

    private(set) var state = State.idle

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let folder = home.appending(path: ".local/share/talktome-server")
    static let setupLog = home.appending(path: "Library/Logs/talktome-server-setup.log")
    private static let agentPlist = home.appending(path: "Library/LaunchAgents/com.talktome.server.plist")
    private static let tokenFile = home.appending(path: ".config/talktome/token")
    /// Where the one-click setup's server listens.
    private static let port = 8766

    /// The model is 2.5 GB: allow for a slow connection, but not for one
    /// that has stopped (or a server that fails to start).
    private static let downloadTimeout: Duration = .seconds(45 * 60)
    private static let stallLimit: TimeInterval = 5 * 60

    /// Apple Silicon, even when this process runs under Rosetta.
    static var isSupported: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// The talktome-server that already runs at login on this Mac, however it
    /// was installed (here, by hand or over SSH).
    static var installed: InstalledAgent? {
        agentArguments.flatMap(InstalledAgent.init(programArguments:))
    }

    private static var agentArguments: [String]? {
        guard let data = try? Data(contentsOf: agentPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["ProgramArguments"] as? [String]
    }

    /// The server requires this token whenever the file exists.
    static var token: String {
        let text = (try? String(contentsOf: tokenFile, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Installs or updates the server at this app's version, then waits until
    /// it answers. Cancelling stops the script; a server already installed
    /// keeps starting in the background.
    func install() async {
        state = .working(.python, download: nil)
        do {
            if Self.installed == nil, Self.isListening(port: Self.port) {
                throw SetupError("Another program already uses port \(Self.port) on this Mac.")
            }
            try await runScript()
            try await waitUntilServing()
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// For snapshots: show a state without running anything.
    func loadPreview(_ state: State) { self.state = state }

    /// Stops the server and removes its launch agent. The files stay.
    func remove() async {
        // The agent's own interpreter: the server may live outside `folder`.
        guard let python = Self.agentArguments?.first else { state = .idle; return }
        do {
            let status = try await Self.run(URL(filePath: python), ["-m", "talktome_server", "uninstall-agent"]) { _ in }
            state = status == 0 ? .idle : .failed("Could not remove the launch agent (exit \(status)).")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    private func runScript() async throws {
        guard let script = Bundle.main.url(forResource: "install-local-server", withExtension: "sh") else {
            throw SetupError("The setup script is missing from the app.")
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let status = try await Self.run(URL(filePath: "/bin/bash"), [script.path(), version]) { [weak self] line in
            if let step = SetupStep(scriptLine: line) { self?.state = .working(step, download: nil) }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let reason = Self.lastLine(of: Self.setupLog) ?? "exit \(status)"
            throw SetupError("Setup failed: \(reason)")
        }
    }

    private func waitUntilServing() async throws {
        let model = ModelDownload.folder(environment: ProcessInfo.processInfo.environment, home: Self.home)
        let clock = ContinuousClock()
        let deadline = clock.now + Self.downloadTimeout
        var watch = StallWatch(limit: Self.stallLimit, start: .now)
        while clock.now < deadline {
            if await Self.isServing(InstalledAgent(port: Self.port).healthURL) { return }
            let bytes = ModelDownload.bytes(in: model)
            if watch.isStalled(bytes: bytes, at: .now) { break }
            state = .working(.model, download: ModelDownload.fraction(downloaded: bytes))
            try await Task.sleep(for: .seconds(1))
        }
        throw SetupError("The server did not start. Check the network and ~/Library/Logs/talktome-server.log, "
                         + "then try again.")
    }

    /// A talktome-server answering at `health`. It opens its port only once
    /// the model has loaded.
    static func isServing(_ health: URL) async -> Bool {
        let request = URLRequest(url: health, timeoutInterval: 2)
        guard let (body, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200 && Health.isOK(body)
    }

    /// Anything accepting TCP connections on 127.0.0.1:`port`, HTTP or not:
    /// the server could not bind it. Connecting to loopback answers at once.
    private static func isListening(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: - Processes

    /// Runs `executable`, handing each stdout line to `onLine` and writing
    /// stderr to the setup log. Returns the exit status; cancelling the task
    /// terminates the process.
    private static func run(
        _ executable: URL, _ arguments: [String], onLine: @escaping @MainActor (String) -> Void
    ) async throws -> Int32 {
        FileManager.default.createFile(atPath: setupLog.path(), contents: nil)
        let log = try FileHandle(forWritingTo: setupLog)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = log
        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                onLine(line)
            }
        } onCancel: {
            process.terminate()
        }
        for await status in exited { return status }
        return -1
    }

    private static func lastLine(of file: URL) -> String? {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}

private struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
