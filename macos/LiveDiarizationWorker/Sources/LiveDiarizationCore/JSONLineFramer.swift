import Foundation

/// Drops an oversized line through its newline, then resumes at the next request.
public struct JSONLineFramer {
    public enum Event: Equatable {
        case line(Data)
        case oversized
    }

    private let maxBytes: Int
    private var buffered = Data()
    private var discarding = false

    public init(maxBytes: Int = 65_536) {
        self.maxBytes = maxBytes
    }

    public mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            if byte == 10 {
                if discarding {
                    discarding = false
                } else if !buffered.isEmpty {
                    events.append(.line(buffered))
                }
                buffered.removeAll(keepingCapacity: true)
            } else if !discarding {
                if buffered.count == maxBytes {
                    buffered.removeAll(keepingCapacity: true)
                    discarding = true
                    events.append(.oversized)
                } else {
                    buffered.append(byte)
                }
            }
        }
        return events
    }

    public mutating func finish() -> [Event] {
        defer {
            buffered.removeAll()
            discarding = false
        }
        return discarding || buffered.isEmpty ? [] : [.line(buffered)]
    }
}
