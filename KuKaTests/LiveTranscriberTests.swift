import AVFAudio
import CoreMedia
import Speech
import XCTest
@testable import KuKa

final class LiveTranscriberTests: XCTestCase {
    func testAVolatileResultGivesFileSecondsAndPlainText() {
        var text = AttributedString("So the ")
        var word = AttributedString("plan")
        word.audioTimeRange = CMTimeRange(start: time(2.0), end: time(2.4))
        text += word

        let result = LiveResult(track: .system, range: CMTimeRange(start: time(1.5), end: time(4)),
                                finalizationTime: time(1.5), text: text)

        XCTAssertEqual(result, LiveResult(track: .system, start: 1.5, end: 4, text: "So the plan",
                                          isFinal: false, finalizedThrough: 1.5))
    }

    func testAResultIsFinalOnceTheFinalizationTimeReachesItsEnd() {
        let range = CMTimeRange(start: time(1.5), end: time(4))

        let atEnd = LiveResult(track: .microphone, range: range, finalizationTime: time(4),
                               text: AttributedString("Ship it."))
        // The analyzer's own timescale can differ from the input's.
        let past = LiveResult(track: .microphone, range: range,
                              finalizationTime: CMTime(seconds: 4.25, preferredTimescale: 1_000_000_000),
                              text: AttributedString("Ship it."))
        let before = LiveResult(track: .microphone, range: range,
                                finalizationTime: CMTime(value: 3_999_999, timescale: 1_000_000),
                                text: AttributedString("Ship it."))

        XCTAssertTrue(atEnd.isFinal)
        XCTAssertTrue(past.isFinal)
        XCTAssertEqual(past.finalizedThrough, 4.25)
        XCTAssertFalse(before.isFinal)
    }

    func testABufferGoesInAtItsExactFrame() throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioTrackWriter.fileFormat, frameCapacity: 320))
        // 4.02 s and 4.06 s: one frame early would overlap the buffer before, and the analyzer
        // would stop with "Audio input timestamp overlaps or precedes prior audio input".
        for frame in [64_320, 64_960] as [CMTimeValue] {
            let audio = WrittenAudio(buffer: buffer, filePosition: Double(frame) / 16_000, rms: 0)
            XCTAssertEqual(audio.startTime, CMTime(value: frame, timescale: 16_000))
        }
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue(seconds * 16_000), timescale: 16_000)
    }
}
