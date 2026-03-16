import XCTest
@testable import InsightKitApp

final class RPCCodecTests: XCTestCase {
    func testEncodeSidecarStatusRequest() throws {
        let req = RPCRequest(id: 1, method: "sidecar.status", params: EmptyParams())
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["id"] as? Int, 1)
        XCTAssertEqual(obj["method"] as? String, "sidecar.status")
    }

    func testDecodeSidecarStatusResponse() throws {
        let json = """
        {"running":true,"pid":123,"version":"0.1.0","build":"20260315","socket_path":"/tmp/test.sock","uptime_sec":60,"live_sessions":0,"ready":true,"python_executable":"/usr/bin/python3","python_version":"3.11.0","last_error_code":"","last_latency_ms":5}
        """.data(using: .utf8)!
        let response = try RPCCodec.decode(SidecarStatusResponse.self, from: json)
        XCTAssertTrue(response.running)
        XCTAssertEqual(response.pid, 123)
        XCTAssertEqual(response.version, "0.1.0")
        XCTAssertTrue(response.ready)
    }

    func testDecodeTranscriptionProgressEvent() throws {
        let json = """
        {"event":"transcription.progress","data":{"job_id":"j1","progress":42,"stage":"transcribing"}}
        """.data(using: .utf8)!
        let event = try RPCCodec.decodeEvent(from: json)
        XCTAssertEqual(event.name, "transcription.progress")
        let progressData = try JSONSerialization.data(withJSONObject: event.data)
        let progress = try RPCCodec.decode(TranscriptionProgressEvent.self, from: progressData)
        XCTAssertEqual(progress.jobId, "j1")
        XCTAssertEqual(progress.progress, 42)
    }

    func testDecodeErrorResponse() throws {
        let json = """
        {"id":1,"error":{"code":-32601,"message":"method not found"}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCRawResponse.self, from: json)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.message, "method not found")
    }
}
