import Foundation
import XCTest
@testable import lodestar

/// Where the parked thread waits: a name the sample must find.
@inline(never)
func stackSamplerTestParksHere(ready: DispatchSemaphore, gate: DispatchSemaphore) {
    ready.signal()
    gate.wait()
}

/// The sampler reads a real thread that is stuck, by name, and leaves it
/// running: a thread suspended and never resumed would be a freeze the
/// watchdog itself made.
final class StackSamplerTests: XCTestCase {
    func testAStuckThreadIsReadByNameAndKeepsRunning() throws {
        let ready = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        var parked: StackSampler?
        let thread = Thread {
            parked = StackSampler.current()
            stackSamplerTestParksHere(ready: ready, gate: gate)
            done.signal()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        let sampler = try XCTUnwrap(parked)
        let addresses = try XCTUnwrap(sampler.addresses(), "a parked thread can be read")
        XCTAssertGreaterThan(addresses.count, 2)
        let names = StackSampler.names(addresses)
        XCTAssertTrue(names.contains { $0.contains("stackSamplerTestParksHere") },
                      "the function it is stuck in is named: \(names.prefix(8))")
        gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "the thread runs on after it was read")
    }

    func testAThreadDoesNotReadItself() {
        XCTAssertNil(StackSampler.current().addresses(), "suspending itself, it would never come back")
    }

    func testTheSignatureOnAnAddressIsTakenOff() {
        XCTAssertEqual(StackSampler.strip(0x002A_0001_0000_1234), 0x0000_0001_0000_1234)
        XCTAssertEqual(StackSampler.strip(0x0000_7FFF_0000_0010), 0x0000_7FFF_0000_0010, "a plain address is kept")
    }

    func testAnAddressWithNoBinaryIsWrittenAsANumber() {
        XCTAssertEqual(StackSampler.name(of: 0x10), "0x10")
    }
}
