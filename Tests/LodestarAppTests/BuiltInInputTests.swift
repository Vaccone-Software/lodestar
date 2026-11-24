import AVFoundation
import XCTest
@testable import lodestar

/// The fallback has to exist before it can be fallen back to.
///
/// A Mac's built-in microphone is the one input that is always present,
/// which is what makes it the right answer when the chosen device
/// delivers nothing. It is found by transport type rather than by name,
/// because the name is localised and the transport is not.
final class BuiltInInputTests: XCTestCase {
    func testThisMacHasOneAndItIsAnInput() throws {
        let builtIn = try XCTUnwrap(AudioInput.builtInInput(),
                                    "every Mac has a built-in microphone")
        let inputs = AudioInput.inputDevices().map(\.id)
        XCTAssertTrue(inputs.contains(builtIn),
                      "and the fallback must be a device that can actually be opened")
    }
}
