import AVFoundation
import XCTest
@testable import lodestar

/// Two microphones, one recognizer: the Mac's is heard while a headset
/// wakes, and the headset takes over at its first buffer with a voice in
/// it — never at a silent one, which is how its telephone link comes up.
final class MicHandoverTests: XCTestCase {
    private func buffer(_ tag: Float, voiced: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for i in 0..<160 { buffer.floatChannelData![0][i] = voiced ? (i == 0 ? tag : 0.05) : 0 }
        return buffer
    }
    private func tag(_ buffer: AVAudioPCMBuffer) -> Float { buffer.floatChannelData![0][0] }

    func testWithoutABridgeTheHeadsetIsHeardSilenceAndAll() {
        var heard: [Float] = []
        let gate = Handover { heard.append(self.tag($0)) }
        gate.fromHeadset(buffer(0, voiced: false))
        gate.fromHeadset(buffer(2, voiced: true))
        XCTAssertEqual(heard, [0, 2], "as it always was")
    }

    func testTheBridgeIsHeardUntilTheHeadsetHasAVoice() {
        var heard: [Float] = []
        var handovers = 0
        let gate = Handover { heard.append(self.tag($0)) }
        gate.onHandover = { _ in handovers += 1 }
        gate.openBridge()
        gate.fromBridge(buffer(1, voiced: true))
        gate.fromHeadset(buffer(0, voiced: false))       // the link, up but silent
        gate.fromBridge(buffer(3, voiced: true))
        gate.fromHeadset(buffer(5, voiced: true))        // the headset hears
        gate.fromBridge(buffer(7, voiced: true))         // let go
        gate.fromHeadset(buffer(0, voiced: false))       // a pause in speech still goes through
        XCTAssertEqual(heard, [1, 3, 5, 0])
        XCTAssertEqual(handovers, 1)
    }

    func testABridgeOpenedLateStandsInForNothing() {
        var heard: [Float] = []
        let gate = Handover { heard.append(self.tag($0)) }
        gate.fromHeadset(buffer(2, voiced: true))
        gate.openBridge()
        gate.fromBridge(buffer(9, voiced: true))
        XCTAssertEqual(heard, [2])
    }
}
