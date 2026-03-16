import Foundation

// MARK: - NDJSON Frame Buffer

final class RPCFrameBuffer {
    private var buffer = Data()

    /// Append incoming data and return any complete NDJSON frames (lines).
    /// Partial frames are buffered until the next append.
    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[(idx + 1)...])
            if line.isEmpty { continue }
            frames.append(Data(line))
        }
        return frames
    }

    func reset() {
        buffer = Data()
    }
}

// MARK: - Handshake

struct RPCHandshake: Codable {
    let insightkit: String
    var push: Bool?

    init(version: String = "1.0", push: Bool? = nil) {
        self.insightkit = version
        self.push = push
    }
}
