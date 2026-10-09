import Foundation

/// Turns the mic's samples into waveform levels at a steady pace. Each level
/// covers a fixed stretch of time, not one capture buffer, so the bars move
/// at the same speed whatever buffer size the microphone delivers.
struct LevelMeter {
    /// Samples per level: 100 ms at 16 kHz, ten bars a second.
    var window = 1600

    private var sum: Float = 0
    private var count = 0

    /// Feeds one sample; returns a level (0…1) when it completes a window.
    mutating func add(_ sample: Int16) -> Float? {
        let s = Float(sample) / 32768
        sum += s * s
        count += 1
        guard count == window else { return nil }
        let rms = (sum / Float(count)).squareRoot()
        sum = 0
        count = 0
        return Self.level(rms: rms)
    }

    /// Maps loudness on a dB scale (-55 dB silent … -12 dB loud) so normal
    /// speech fills the bars instead of barely moving them.
    static func level(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 55) / 43))
    }
}
