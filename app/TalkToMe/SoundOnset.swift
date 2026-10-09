/// Notices when a microphone starts delivering sound. Bluetooth headsets send
/// exact zeros for about half a second after they start; anything else,
/// even a quiet room, is never exactly zero. A mic that only ever sends
/// zeros (a closed laptop's) counts as live after a second, so the user is
/// not left waiting for a start sound that never comes.
struct SoundOnset {
    private(set) var isLive = false
    private var silentSeconds = 0.0

    /// Feeds one buffer's peak and duration; true only for the buffer that
    /// makes the mic live.
    mutating func isFirstSound(peak: Float, seconds: Double) -> Bool {
        guard !isLive else { return false }
        silentSeconds += seconds
        isLive = peak > 0 || silentSeconds >= 1
        return isLive
    }
}
