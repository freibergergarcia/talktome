import Foundation

/// Opt-in debug log (Settings → Advanced) at ~/Library/Logs/TalkToMe.log.
/// Records what happened and when, never what was said.
enum EventLog {
    nonisolated(unsafe) static var enabled = false

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/TalkToMe.log")
    private static let queue = DispatchQueue(label: "talktome.eventlog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        guard enabled else { return }
        // Called from several threads: format on the log's own queue.
        let now = Date()
        queue.async {
            guard let data = "\(stamp.string(from: now)) \(message)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
