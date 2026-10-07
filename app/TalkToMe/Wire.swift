import Foundation

// Request encoding for RemoteTranscriber, kept free of app dependencies so
// the unit tests can compile it on its own.

/// Minimal multipart/form-data builder.
struct Multipart {
    let boundary: String
    private var data = Data()

    init(boundary: String) { self.boundary = boundary }

    mutating func addField(_ name: String, _ value: String) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data file: Data) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        data.append("Content-Type: \(contentType)\r\n\r\n")
        data.append(file)
        data.append("\r\n")
    }

    func finish() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

/// RIFF/WAVE container around raw PCM.
enum WAV {
    static func encode(pcm16 pcm: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var out = Data(capacity: 44 + pcm.count)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        out.append(pcm)
        return out
    }
}
