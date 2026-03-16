import XCTest
@testable import InsightKitApp

final class RPCTransportTests: XCTestCase {
    func testFrameSplitting() {
        let buffer = RPCFrameBuffer()
        let data = "{\"id\":1,\"result\":{}}\n{\"event\":\"test\"}\n".data(using: .utf8)!
        let frames = buffer.append(data)
        XCTAssertEqual(frames.count, 2)
    }

    func testPartialFrame() {
        let buffer = RPCFrameBuffer()
        let part1 = "{\"id\":1,".data(using: .utf8)!
        let part2 = "\"result\":{}}\n".data(using: .utf8)!
        let frames1 = buffer.append(part1)
        XCTAssertEqual(frames1.count, 0, "Partial frame should not produce output")
        let frames2 = buffer.append(part2)
        XCTAssertEqual(frames2.count, 1)
    }

    func testEmptyLine() {
        let buffer = RPCFrameBuffer()
        let data = "\n\n{\"id\":1}\n\n".data(using: .utf8)!
        let frames = buffer.append(data)
        XCTAssertEqual(frames.count, 1, "Empty lines should be skipped")
    }

    func testHandshakeEncodeDecode() {
        let handshake = RPCHandshake(version: "1.0")
        let data = try! JSONEncoder().encode(handshake)
        let decoded = try! JSONDecoder().decode(RPCHandshake.self, from: data)
        XCTAssertEqual(decoded.insightkit, "1.0")
    }

    func testHandshakeWithPush() {
        let handshake = RPCHandshake(version: "1.0", push: true)
        let data = try! JSONEncoder().encode(handshake)
        let decoded = try! JSONDecoder().decode(RPCHandshake.self, from: data)
        XCTAssertEqual(decoded.insightkit, "1.0")
        XCTAssertEqual(decoded.push, true)
    }

    func testFrameBufferReset() {
        let buffer = RPCFrameBuffer()
        let partial = "{\"id\":1,".data(using: .utf8)!
        _ = buffer.append(partial)
        buffer.reset()
        let fresh = "{\"id\":2}\n".data(using: .utf8)!
        let frames = buffer.append(fresh)
        XCTAssertEqual(frames.count, 1)
        let obj = try! JSONSerialization.jsonObject(with: frames[0]) as! [String: Any]
        XCTAssertEqual(obj["id"] as? Int, 2)
    }
}
