import Foundation

// What the one-click local server setup reads and measures, kept free of app
// dependencies so the unit tests can compile it on its own.

/// The stages of setting up talktome-server on this Mac. The first three are
/// scripts/install-local-server.sh's ("step <name>" on its stdout); then the
/// app waits while the server downloads the model and starts.
enum SetupStep: Int, CaseIterable, Comparable {
    case python, packages, agent, model, ready

    /// The step a line of the script's output announces, nil for any other line.
    init?(scriptLine line: String) {
        switch line.trimmingCharacters(in: .whitespaces) {
        case "step python": self = .python
        case "step packages": self = .packages
        case "step agent": self = .agent
        case "step done": self = .model
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .python: "Python"
        case .packages: "talktome-server"
        case .agent: "Start at login"
        case .model: "Parakeet model"
        case .ready: "Ready"
        }
    }

    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }
}

/// The model download, measured by what has reached the Hugging Face cache.
enum ModelDownload {
    /// config.json and model.safetensors at the revision talktome-server pins.
    static let totalBytes: Int64 = 244_093 + 2_508_288_736

    /// Where huggingface_hub keeps this model: $HF_HUB_CACHE, else
    /// $HF_HOME/hub, else ~/.cache/huggingface/hub.
    static func folder(environment: [String: String], home: URL) -> URL {
        let hub = environment["HF_HUB_CACHE"].map { URL(filePath: $0) }
            ?? environment["HF_HOME"].map { URL(filePath: $0).appending(path: "hub") }
            ?? home.appending(path: ".cache/huggingface/hub")
        return hub.appending(path: "models--mlx-community--parakeet-tdt-0.6b-v3")
    }

    /// Bytes in the model's blobs, finished or still downloading (.incomplete).
    static func bytes(in folder: URL) -> Int64 {
        let blobs = folder.appending(path: "blobs")
        let files = (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { total, file in
            let size = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize
            return total + Int64(size ?? 0)
        }
    }

    static func fraction(downloaded: Int64) -> Double {
        min(1, max(0, Double(downloaded) / Double(totalBytes)))
    }
}

/// talktome-server's GET /health answer, {"ok": true}: tells it apart from
/// anything else that might answer on its port.
enum Health {
    static func isOK(_ body: Data) -> Bool {
        struct Answer: Decodable { let ok: Bool }
        return (try? JSONDecoder().decode(Answer.self, from: body))?.ok == true
    }
}

/// Notices when a download makes no progress for `limit` seconds: a lost
/// connection, a full disk or a server that fails to start.
struct StallWatch {
    let limit: TimeInterval
    private var lastBytes: Int64 = -1
    private var lastProgress: Date

    init(limit: TimeInterval, start: Date) {
        self.limit = limit
        lastProgress = start
    }

    mutating func isStalled(bytes: Int64, at now: Date) -> Bool {
        if bytes != lastBytes {
            if lastBytes >= 0 { lastProgress = now }
            lastBytes = bytes
        }
        return now.timeIntervalSince(lastProgress) > limit
    }
}

/// How an existing talktome-server launch agent runs, read from the
/// ProgramArguments of its plist.
struct InstalledAgent: Equatable {
    var host = "127.0.0.1"
    var port = 8766

    /// Listening on this Mac only, as the one-click setup installs it.
    var isLocalOnly: Bool { ["127.0.0.1", "localhost", "::1"].contains(host) }

    /// The app connects over loopback whatever address the server listens on;
    /// over IPv6 only if that is all it listens on.
    var baseURL: String { origin + "/v1" }
    var healthURL: URL { URL(string: origin + "/health")! }

    private var origin: String { host == "::1" ? "http://[::1]:\(port)" : "http://127.0.0.1:\(port)" }
}

extension InstalledAgent {
    init?(programArguments args: [String]) {
        guard args.contains("talktome_server"), args.contains("serve") else { return nil }
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let host = value(after: "--host") { self.host = host }
        if let port = value(after: "--port").flatMap(Int.init) { self.port = port }
    }
}
