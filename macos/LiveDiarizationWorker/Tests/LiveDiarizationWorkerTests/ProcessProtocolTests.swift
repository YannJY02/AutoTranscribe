import Darwin
import Foundation
import XCTest

final class ProcessProtocolTests: XCTestCase {
    private struct ProtocolFailure: Error, CustomStringConvertible {
        let description: String
    }

    func testEachRequestRespondsWhileStdinRemainsOpen() throws {
        let override = ProcessInfo.processInfo.environment["INSIGHTKIT_LIVE_DIARIZATION_TEST_BINARY"]
        let binary = override.map { URL(fileURLWithPath: $0) }
            ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("InsightKitLiveDiarization")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "Worker executable missing: \(binary.path)")

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = binary
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var buffered = Data()
        for id in [1, 2] {
            // The first reply must arrive before sending the second request, and
            // stdin stays open throughout. No action here initializes a model.
            let request = Data("{\"id\":\(id),\"action\":\"unknown\",\"session_id\":\"pipe-test\"}\n".utf8)
            try input.fileHandleForWriting.write(contentsOf: request)
            let reply = try readReply(descriptor: descriptor, buffered: &buffered, timeout: 2)
            XCTAssertEqual(reply["id"] as? Int, id)
            XCTAssertEqual(reply["ok"] as? Bool, false)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "unsupported_action")
            XCTAssertTrue(process.isRunning, "The persistent worker exited between requests")
        }
    }

    private func readReply(descriptor: Int32, buffered: inout Data, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                let line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ProtocolFailure(description: "Worker response must be one JSON object")
                }
                return reply
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw ProtocolFailure(description: "Worker did not respond within \(timeout) seconds while stdin remained open")
            }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorState, 1, Int32(ceil(remaining * 1_000)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ready == 0 { continue }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { throw ProtocolFailure(description: "Worker closed stdout before replying") }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count <= 65_536 else { throw ProtocolFailure(description: "Worker response exceeded the test limit") }
        }
    }
}
