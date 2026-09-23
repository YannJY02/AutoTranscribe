import Darwin
import Foundation
import LiveDiarizationCore

@main
struct WorkerMain {
    static func main() {
        // Some dependencies fall back to print(). Reserve a private descriptor for
        // protocol replies before routing every ordinary stdout write to stderr.
        let protocolDescriptor = dup(STDOUT_FILENO)
        guard protocolDescriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(1) }
        signal(SIGPIPE, SIG_IGN)
        let output = FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
        let controller = SessionController { try LocalLSEENDEngine(request: $0) }
        defer { controller.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var framer = JSONLineFramer()

        func write(_ events: [JSONLineFramer.Event]) throws {
            for event in events {
                let response: WorkerResponse
                switch event {
                case .line(let data):
                    response = autoreleasepool { controller.handle(line: data) }
                case .oversized:
                    response = controller.protocolError("request_too_large", "JSON request exceeds 65536 bytes")
                }
                var data = try encoder.encode(response)
                data.append(10)
                try output.write(contentsOf: data)
            }
        }

        do {
            var inputBuffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                // FileHandle.read(upToCount:) can wait for a full buffer or EOF
                // on a pipe. POSIX read returns the bytes currently available,
                // allowing each request to reply while stdin remains open.
                let count = inputBuffer.withUnsafeMutableBytes {
                    Darwin.read(STDIN_FILENO, $0.baseAddress!, $0.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try write(framer.append(Data(inputBuffer.prefix(count))))
            }
            try write(framer.finish())
        } catch {
            let message = Data("Live diarization worker I/O failed: \(error.localizedDescription)\n".utf8)
            try? FileHandle.standardError.write(contentsOf: message)
            controller.close()
            exit(1)
        }
    }
}
