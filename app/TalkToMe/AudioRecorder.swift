import AVFoundation

/// Records a microphone into 16 kHz mono int16 PCM, the native rate of the
/// speech models. Converting while recording means stopping is instant: the
/// clip is ready to send.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    /// Live input level, 0…1, for the recording UI. Called on the audio thread.
    var onLevel: ((Float) -> Void)?

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var converter: AVAudioConverter?
    private var rawPeak: Float = 0
    private var buffers = 0

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    enum RecorderError: LocalizedError {
        case noMicrophone
        case noInput(String)
        var errorDescription: String? {
            switch self {
            // Desktop Macs (Mac Studio, Mac mini) have no built-in mic.
            case .noMicrophone: "No microphone found. Connect one, or check System Settings → Sound → Input."
            case .noInput(let name): "\(name) is not delivering audio. Pick another microphone in Settings."
            }
        }
    }

    func start(device: Microphones.Device?) throws {
        guard !Microphones.inputs().isEmpty else { throw RecorderError.noMicrophone }
        lock.withLock { pcm.removeAll(keepingCapacity: true) }
        // A fresh engine every time. A reused one remembers the mic's format,
        // and when the hardware changes underneath it (another app switches
        // the sample rate, a headset reconnects) installTap raises an
        // Objective-C exception that Swift cannot catch: the app crashes.
        engine.stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            try input.auAudioUnit.setDeviceID(device.id)
        }
        // The hardware side of the input node: always the device's current format.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput(device?.name ?? "The microphone")
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.format)
        rawPeak = 0
        buffers = 0
        EventLog.write("recorder start: \(device?.name ?? "default") \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch")

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Decodes any audio file AVFoundation can read into the recorder's
    /// format. Used by `--transcribe` to exercise engines without a mic.
    static func pcm16(contentsOf url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let capacity = AVAudioFrameCount(Double(source.frameLength) * sampleRate / file.processingFormat.sampleRate) + 32
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
        return Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
    }

    /// Stops recording and returns everything captured since `start()`.
    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let data = lock.withLock { pcm }
        EventLog.write("recorder stop: \(self.buffers) buffers, peak \(self.rawPeak), \(data.count) bytes")
        return data
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        buffers += 1
        if let raw = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { rawPeak = max(rawPeak, abs(raw[i])) }
        }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }

        let count = Int(out.frameLength)
        lock.withLock { pcm.append(UnsafeBufferPointer(start: samples, count: count)) }

        var sum: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / 32768
            sum += s * s
        }
        // Map loudness on a dB scale (-55 dB silent … -12 dB loud) so normal
        // speech fills the bars instead of barely moving them.
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(min(1, max(0, (db + 55) / 43)))
    }
}
