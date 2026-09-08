import AVFoundation
import XCTest
@testable import InsightKitApp

final class AudioMixBusTests: XCTestCase {
    func testMixedModeUsesHeadroomInsteadOfClipping() {
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
        XCTAssertLessThan(received[0], 0.95)
        XCTAssertGreaterThan(received[0], 0.85)
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

    func testResamplingPreservesDurationAndContinuityAcrossInputBuffers() async {
        for sampleRate in [48_000.0, 44_100.0] {
            let samples = (0..<(100 * 2_048)).map {
                Float(0.2 * sin(Double($0) * 2 * .pi * 997 / sampleRate))
            }
            let streaming = AudioMixBus()
            let continuous = AudioMixBus()
            var streamed: [Float] = []
            var reference: [Float] = []
            streaming.onMixedSamples = { streamed.append(contentsOf: $0) }
            continuous.onMixedSamples = { reference.append(contentsOf: $0) }
            for offset in stride(from: 0, to: samples.count, by: 2_048) {
                streaming.ingestMicrophone(makeBuffer(
                    samples: Array(samples[offset..<(offset + 2_048)]), sampleRate: sampleRate
                ))
            }
            continuous.ingestMicrophone(makeBuffer(samples: samples, sampleRate: sampleRate))
            await streaming.finish()
            await continuous.finish()

            let expectedSamples = Double(samples.count) * 16_000 / sampleRate
            XCTAssertEqual(Double(streamed.count), expectedSamples, accuracy: 8,
                           "Only the converter's one-time priming tail may remain, not loss on every buffer")
            XCTAssertEqual(streamed.count, reference.count)
            let largestDifference = zip(streamed, reference).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(largestDifference, 0.0001, "Buffer boundaries must not add clicks or phase jumps")
        }
    }

    func testMixedResamplingKeepsEachSourcesConverterIndependent() async {
        let bus = AudioMixBus()
        bus.setMode(.mixed)
        var received: [Float] = []
        bus.onMixedSamples = { received.append(contentsOf: $0) }
        let phaseIncrement: Double = 2.0 * Double.pi * 997.0 / 48_000.0
        for index in 0..<40 {
            let samples: [Float] = (0..<2_048).map { sampleIndex in
                let phase = Double(index * 2_048 + sampleIndex) * phaseIncrement
                return Float(0.2 * sin(phase))
            }
            bus.ingestMicrophone(makeBuffer(samples: samples, sampleRate: 48_000))
            bus.ingestSystemAudio(makeBuffer(samples: samples.map { -$0 }, sampleRate: 48_000))
        }
        await bus.finish()

        XCTAssertEqual(Double(received.count), Double(40 * 2_048) / 3, accuracy: 8)
        XCTAssertLessThan(received.map { abs($0) }.max() ?? 1, 0.0001,
                          "Opposite source signals must cancel without sharing resampler history")
    }

    func testFinishFlushesTheMixedTailExactlyOnce() async {
        let bus = AudioMixBus()
        bus.setMode(.mixed)
        var received: [Float] = []
        bus.onMixedSamples = { received.append(contentsOf: $0) }
        bus.ingestMicrophone(makeBuffer(samples: Array(repeating: 0.2, count: 1_600)))

        await bus.finish()
        XCTAssertEqual(received.count, 1_600)
        await bus.finish()
        XCTAssertEqual(received.count, 1_600)
    }

    private func makeBuffer(samples: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        return buffer
    }
}
