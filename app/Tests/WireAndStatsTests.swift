import Foundation
import Testing

@Suite struct WAVTests {
    @Test func headerDescribes16kMonoPCM() {
        let pcm = Data(repeating: 0, count: 32_000)
        let wav = WAV.encode(pcm16: pcm, sampleRate: 16_000)
        #expect(wav.count == 44 + pcm.count)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(uint32(wav, at: 24) == 16_000)      // sample rate
        #expect(uint32(wav, at: 28) == 32_000)      // byte rate
        #expect(uint16(wav, at: 22) == 1)           // channels
        #expect(uint16(wav, at: 34) == 16)          // bits per sample
        #expect(uint32(wav, at: 40) == UInt32(pcm.count))
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}

@Suite struct MultipartTests {
    @Test func encodesFieldsAndFileWithClosingBoundary() {
        var body = Multipart(boundary: "B")
        body.addField("model", "whisper-1")
        body.addFile("file", filename: "a.wav", contentType: "audio/wav", data: Data("xyz".utf8))
        let text = String(decoding: body.finish(), as: UTF8.self)
        #expect(text.contains("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nxyz\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
    }
}

@Suite struct StatsTests {
    @Test func recordsWordsAndLatency() {
        var stats = Stats()
        stats.record(text: "one two  three\nfour", seconds: 2, latencyMs: 300)
        #expect(stats.today.words == 4)
        #expect(stats.today.dictations == 1)
        #expect(stats.lastLatencyMs == 300)
    }

    @Test func timeSavedNeverNegative() {
        var stats = Stats()
        stats.record(text: "hi", seconds: 120, latencyMs: 100)
        #expect(stats.minutesSavedToday == 0)
    }

    @Test func streakCountsToday() {
        var stats = Stats()
        #expect(stats.streak == 0)
        stats.record(text: "hello", seconds: 1, latencyMs: 1)
        #expect(stats.streak == 1)
    }
}
