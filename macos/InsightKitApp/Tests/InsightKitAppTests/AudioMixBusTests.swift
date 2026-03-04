import AVFoundation
import XCTest
@testable import InsightKitApp

final class AudioMixBusTests: XCTestCase {
    func testMixedModeClampsOutput() {
        let bus = AudioMixBus()
        bus.setMode(.mixed)

        let exp = expectation(description: "mixed output")
        var received: [Float] = []
        bus.onMixedSamples = { samples in
            received.append(contentsOf: samples)
            if received.count >= 2 {
                exp.fulfill()
            }
        }

        bus.ingestMicrophone(makeBuffer(samples: [1.0, 1.0]))
        bus.ingestSystemAudio(makeBuffer(samples: [1.0, -1.0]))

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(received[1], 0.0, accuracy: 0.0001)
    }

    func testMicrophoneModeIgnoresSystemAudio() {
        let bus = AudioMixBus()
        bus.setMode(.microphone)

        let exp = expectation(description: "mic output")
        var callCount = 0
        bus.onMixedSamples = { _ in
            callCount += 1
            exp.fulfill()
        }

        bus.ingestSystemAudio(makeBuffer(samples: [0.4, 0.4]))
        bus.ingestMicrophone(makeBuffer(samples: [0.2, 0.3]))

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(callCount, 1)
    }

    private func makeBuffer(samples: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        return buffer
    }
}
