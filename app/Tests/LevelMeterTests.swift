import Testing

@Suite struct LevelMeterTests {
    /// Feeds `samples` in buffers of `size`; returns every level emitted.
    private func levels(_ samples: [Int16], buffer size: Int, meter: inout LevelMeter) -> [Float] {
        stride(from: 0, to: samples.count, by: size).flatMap { start in
            samples[start..<min(start + size, samples.count)].compactMap { meter.add($0) }
        }
    }

    private func levels(_ samples: [Int16], buffer size: Int) -> [Float] {
        var meter = LevelMeter()
        return levels(samples, buffer: size, meter: &meter)
    }

    /// One second of a constant signal at -20 dB, about normal speech.
    private let speech = [Int16](repeating: 3277, count: 16_000)

    @Test func pacedByTimeNotBufferSize() {
        let reference = levels(speech, buffer: 1600)
        #expect(reference.count == 10)
        for size in [160, 441, 1024, 4000, 16_000] {
            #expect(levels(speech, buffer: size) == reference)
        }
    }

    @Test func carriesPartialWindowsAcrossBuffers() {
        var meter = LevelMeter()
        let half = [Int16](repeating: 3277, count: 1000)
        #expect(levels(half, buffer: 1000, meter: &meter).isEmpty)
        #expect(levels(half, buffer: 1000, meter: &meter).count == 1)
    }

    @Test func silenceIsZeroAndSpeechFillsTheBars() {
        #expect(levels([Int16](repeating: 0, count: 16_000), buffer: 1600).allSatisfy { $0 == 0 })
        #expect(levels(speech, buffer: 1600).allSatisfy { $0 > 0.7 && $0 < 0.9 })
        #expect(levels([Int16](repeating: .max, count: 16_000), buffer: 1600).allSatisfy { $0 == 1 })
    }
}
