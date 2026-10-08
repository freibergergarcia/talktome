import Foundation
import Testing

@Suite struct SetupStepTests {
    @Test func readsTheScriptsProgressLines() {
        #expect(SetupStep(scriptLine: "step python") == .python)
        #expect(SetupStep(scriptLine: "step packages") == .packages)
        #expect(SetupStep(scriptLine: "step agent") == .agent)
        // The script is done; the app then waits while the server fetches the model.
        #expect(SetupStep(scriptLine: "step done") == .model)
    }

    @Test func ignoresOtherOutput() {
        #expect(SetupStep(scriptLine: "Installed /tmp/com.talktome.server.plist") == nil)
        #expect(SetupStep(scriptLine: "") == nil)
    }

    @Test func stepsAreOrdered() {
        #expect(SetupStep.python < .packages && .packages < .agent && .agent < .model && .model < .ready)
    }
}

@Suite struct ModelDownloadTests {
    private let home = URL(filePath: "/Users/someone")
    private let repo = "models--mlx-community--parakeet-tdt-0.6b-v3"

    @Test func findsTheHuggingFaceCache() {
        #expect(ModelDownload.folder(environment: [:], home: home).path() == "/Users/someone/.cache/huggingface/hub/\(repo)")
        #expect(ModelDownload.folder(environment: ["HF_HOME": "/data/hf"], home: home).path() == "/data/hf/hub/\(repo)")
        let both = ["HF_HOME": "/data/hf", "HF_HUB_CACHE": "/fast/hub"]
        #expect(ModelDownload.folder(environment: both, home: home).path() == "/fast/hub/\(repo)")
    }

    @Test func countsFinishedAndPartialBlobs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let blobs = folder.appending(path: "blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 1_000).write(to: blobs.appending(path: "4f469c2e"))
        try Data(count: 500).write(to: blobs.appending(path: "05e01c7f.incomplete"))

        #expect(ModelDownload.bytes(in: folder) == 1_500)
        #expect(ModelDownload.bytes(in: folder.appending(path: "missing")) == 0)
    }

    @Test func fractionStaysBetweenZeroAndOne() {
        #expect(ModelDownload.fraction(downloaded: 0) == 0)
        #expect(abs(ModelDownload.fraction(downloaded: ModelDownload.totalBytes / 2) - 0.5) < 0.001)
        #expect(ModelDownload.fraction(downloaded: ModelDownload.totalBytes * 2) == 1)
    }
}

@Suite struct InstalledAgentTests {
    private let python = "/Users/someone/.local/share/talktome-server/venv/bin/python3.12"

    @Test func readsHostAndPort() {
        let agent = InstalledAgent(programArguments: [
            python, "-m", "talktome_server", "serve", "--host", "0.0.0.0", "--port", "9000", "--model", "m",
        ])
        #expect(agent == InstalledAgent(host: "0.0.0.0", port: 9000))
        #expect(agent?.isLocalOnly == false)
    }

    @Test func defaultsMatchTheServer() {
        let agent = InstalledAgent(programArguments: [python, "-m", "talktome_server", "serve"])
        #expect(agent == InstalledAgent(host: "127.0.0.1", port: 8766))
        #expect(agent?.isLocalOnly == true)
    }

    @Test func rejectsOtherPrograms() {
        #expect(InstalledAgent(programArguments: ["/usr/bin/true"]) == nil)
    }

    @Test func connectsTheWayTheServerListens() {
        #expect(InstalledAgent(host: "0.0.0.0", port: 8766).baseURL == "http://127.0.0.1:8766/v1")
        #expect(InstalledAgent(host: "localhost", port: 9000).baseURL == "http://127.0.0.1:9000/v1")
        #expect(InstalledAgent(host: "::1", port: 8766).baseURL == "http://[::1]:8766/v1")
        #expect(InstalledAgent(host: "0.0.0.0", port: 9000).healthURL.absoluteString == "http://127.0.0.1:9000/health")
        #expect(InstalledAgent(host: "::1", port: 8766).healthURL.absoluteString == "http://[::1]:8766/health")
    }
}

@Suite struct HealthTests {
    @Test func onlyTalktomeServersAnswerOK() {
        #expect(Health.isOK(Data(#"{"ok": true}"#.utf8)))
        #expect(!Health.isOK(Data(#"{"ok": false}"#.utf8)))
        #expect(!Health.isOK(Data(#"{"status": "healthy"}"#.utf8)))
        #expect(!Health.isOK(Data("OK".utf8)))
    }
}

@Suite struct StallTests {
    private let start = Date(timeIntervalSince1970: 0)

    /// Feeds (seconds since start, bytes) samples; returns whether each one counted as stalled.
    private func stalls(_ samples: [(TimeInterval, Int64)]) -> [Bool] {
        var watch = StallWatch(limit: 300, start: start)
        return samples.map { watch.isStalled(bytes: $0.1, at: start.addingTimeInterval($0.0)) }
    }

    @Test func progressKeepsItAlive() {
        // Progress at 400 s; 650 s is only 250 s after it.
        #expect(stalls([(200, 0), (400, 10), (650, 10)]) == [false, false, false])
    }

    @Test func stallsAfterTheLimitWithoutProgress() {
        #expect(stalls([(10, 5), (311, 5)]) == [false, true])
    }
}
