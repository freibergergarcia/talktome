import AVFoundation
import Foundation
import Speech

/// Turns 16 kHz mono int16 PCM into text.
protocol Transcriber {
    var name: String { get }
    func transcribe(_ pcm: Data) async throws -> String
}

enum TranscriberError: LocalizedError {
    case server(Int, String)
    case badURL
    case localeUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .server(let code, let body): "Server returned \(code): \(body.prefix(120))"
        case .badURL: "The server URL in Settings is not valid."
        case .localeUnsupported(let id): "Apple speech does not support \(id) on this Mac."
        }
    }
}

// MARK: - Remote (OpenAI-compatible)

/// Any server that implements OpenAI's `POST /v1/audio/transcriptions`:
/// talktome-server, OpenAI itself, or other self-hosted servers.
struct RemoteTranscriber: Transcriber {
    let baseURL: URL
    let apiKey: String
    let model: String

    /// Short label for the UI: the host, without a trailing ".local".
    var name: String {
        guard let host = baseURL.host() else { return "Server" }
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Fails fast when the server is asleep or out of reach, so the fallback
    /// takes over without a long stall. Any HTTP answer counts as reachable.
    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await Self.session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    func transcribe(_ pcm: Data) async throws -> String {
        let boundary = "talktome-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Multipart(boundary: boundary)
        body.addField("model", model)
        body.addField("response_format", "json")
        body.addFile("file", filename: "dictation.wav", contentType: "audio/wav",
                     data: WAV.encode(pcm16: pcm, sampleRate: Int(AudioRecorder.sampleRate)))

        let (data, response) = try await Self.session.upload(for: request, from: body.finish())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw TranscriberError.server(status, String(decoding: data, as: UTF8.self))
        }
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple on-device

/// Apple's SpeechTranscriber (macOS 26+). Fully on-device, no third-party
/// code. Works in one language at a time.
struct AppleTranscriber: Transcriber {
    let localeID: String
    let name = "Apple"

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    func transcribe(_ pcm: Data) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw TranscriberError.localeUnsupported(localeID)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // First use of a language downloads its model; later calls are a no-op.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? AudioRecorder.format
        let buffer = try Self.buffer(from: pcm, convertedTo: format)

        let collect = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }

        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        try await analyzer.prepareToAnalyze(in: format)
        _ = try await analyzer.analyzeSequence(input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buffer(from pcm: Data, convertedTo format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(pcm.count / 2)
        let source = AVAudioPCMBuffer(pcmFormat: AudioRecorder.format, frameCapacity: frames)!
        source.frameLength = frames
        pcm.withUnsafeBytes { raw in
            source.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        if format == AudioRecorder.format { return source }

        let converter = AVAudioConverter(from: AudioRecorder.format, to: format)!
        let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / AudioRecorder.sampleRate) + 32
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return out
    }
}
