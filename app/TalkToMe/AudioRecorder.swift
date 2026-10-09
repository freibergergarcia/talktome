import AVFoundation

/// Records a microphone into 16 kHz mono int16 PCM, the native rate of the
/// speech models, ready to send the moment recording stops.
///
/// A capture session, not AVAudioEngine: the engine first opens the system's
/// default input and only then switches to the chosen mic. With AirPods as
/// the default that costs seconds while they switch into headset mode, and
/// when the switch lands mid-recording the engine stops itself. A capture
/// session opens only the chosen mic, and converts to 16 kHz itself.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    /// Live input level, 0…1, for the recording UI. Called on the audio queue.
    var onLevel: ((Float) -> Void)?

    /// Runs every start and stop in order: starting blocks until the mic
    /// runs, and a stop must wait for a slow start.
    private let queue = DispatchQueue(label: "talktome.recorder", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "talktome.recorder.audio", qos: .userInteractive)
    // Used only on `queue`.
    private var session: AVCaptureSession?
    private var observer: NSObjectProtocol?
    // Shared with the audio queue, under `lock`.
    private let lock = NSLock()
    private var pcm = Data()
    private var peak: Float = 0
    private var buffers = 0
    private var onset = SoundOnset()
    private var onSound: (@Sendable () -> Void)?

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

    /// Starts recording from the microphone picked in Settings (`preferredUID`),
    /// or the automatic choice. `onSound` runs once, on the audio queue, when
    /// the first sound arrives.
    func start(preferredUID: String?, onSound: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                done.resume(with: Result { try self.begin(preferredUID: preferredUID, onSound: onSound) })
            }
        }
    }

    /// Stops recording and returns everything captured since `start`.
    func stop() async -> Data {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: self.end()) }
        }
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

    // MARK: - On the queue

    private func begin(preferredUID: String?, onSound: @escaping @Sendable () -> Void) throws {
        guard let device = Microphones.resolve(preferredUID: preferredUID) else { throw RecorderError.noMicrophone }
        // Capture devices share Core Audio's UIDs.
        guard let mic = AVCaptureDevice(uniqueID: device.uid),
              let input = try? AVCaptureDeviceInput(device: mic) else { throw RecorderError.noInput(device.name) }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.noInput(device.name)
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        lock.withLock {
            pcm.removeAll(keepingCapacity: true)
            peak = 0
            buffers = 0
            onset = SoundOnset()
            self.onSound = onSound
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            EventLog.write("recorder error: \(error?.localizedDescription ?? "unknown")")
        }
        self.session = session
        EventLog.write("recorder start: \(device.name)")
        session.startRunning()
        guard session.isRunning else {
            _ = end()
            throw RecorderError.noInput(device.name)
        }
    }

    private func end() -> Data {
        session?.stopRunning()
        session = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        // Take in any buffer still on its way.
        audioQueue.sync {}
        let (data, buffers, peak) = lock.withLock {
            onSound = nil
            return (pcm, self.buffers, self.peak)
        }
        EventLog.write("recorder stop: \(buffers) buffers, peak \(peak), \(data.count) bytes")
        return data
    }

    // MARK: - On the audio queue

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mSampleRate == Self.sampleRate, format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
              format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              let block = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        let count = length / 2
        guard copied == kCMBlockBufferNoErr, count > 0 else { return }

        var loudest: Float = 0
        var sum: Float = 0
        bytes.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let s = Float(sample) / 32768
                loudest = max(loudest, abs(s))
                sum += s * s
            }
        }
        let firstSound: (@Sendable () -> Void)? = lock.withLock {
            pcm.append(bytes)
            buffers += 1
            peak = max(peak, loudest)
            return onset.isFirstSound(peak: loudest, seconds: Double(count) / Self.sampleRate) ? onSound : nil
        }
        firstSound?()

        // Map loudness on a dB scale (-55 dB silent … -12 dB loud) so normal
        // speech fills the bars instead of barely moving them.
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(min(1, max(0, (db + 55) / 43)))
    }
}
