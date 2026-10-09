import Testing

@Suite struct SoundOnsetTests {
    /// Feeds buffers with these peaks; returns which ones counted as the first sound.
    private func firsts(_ peaks: [Float], seconds: Double = 0.1) -> [Bool] {
        var onset = SoundOnset()
        return peaks.map { onset.isFirstSound(peak: $0, seconds: seconds) }
    }

    @Test func waitsOutABluetoothHeadsetsZeros() {
        #expect(firsts([0, 0, 0, 0, 0, 0.0007, 0.02]) == [false, false, false, false, false, true, false])
    }

    @Test func aWorkingMicIsLiveAtOnce() {
        #expect(firsts([0.001, 0.3]) == [true, false])
    }

    @Test func aMicThatOnlySendsZerosCountsAfterASecond() {
        #expect(firsts([0, 0, 0, 0, 0], seconds: 0.25) == [false, false, false, true, false])
    }
}
