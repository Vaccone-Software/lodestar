import XCTest
@testable import lodestar
@testable import LodestarCore

/// The facts about you, from a Settings row to the sealed file: written only
/// once the record has opened, sealed off the main thread, moved in from an
/// older config without losing an edit made meanwhile, and never brought
/// back by a write the deletion of the record overtook.
final class PersonKeeperTests: XCTestCase {
    private var directory: URL!
    private var queue: DispatchQueue!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = DispatchQueue(label: "test.person")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var ring: Vault.Ring { SealedFixture.vault(directory).ring(.health) }

    private func keeper() -> PersonKeeper {
        PersonKeeper(directory: directory, ring: ring, queue: queue)
    }

    private var onDisk: PersonFile.Read { PersonFile(directory: directory, ring: ring).read() }

    /// Every queued write made, and its answer heard on main.
    private func settle(_ keeper: PersonKeeper) {
        keeper.drainForTesting()
        let heard = expectation(description: "main")
        DispatchQueue.main.async { heard.fulfill() }
        wait(for: [heard], timeout: 5)
    }

    func testARowsValueIsSealedOnceTheRecordHasOpened() {
        let keeper = keeper()
        XCTAssertEqual(keeper.set("health.sex", to: .string("female"), healthOn: true),
                       "the health record has not opened yet", "nothing is written over a record not yet read")
        var changes = 0
        keeper.changed = { changes += 1 }
        keeper.read(.person(Person()))
        XCTAssertNil(keeper.set("health.sex", to: .string("female"), healthOn: true))
        XCTAssertNil(keeper.set("health.born", to: .string("1990"), healthOn: true))
        XCTAssertEqual(keeper.person, Person(born: 1990, sex: "female"), "the row shows it at once")
        settle(keeper)
        XCTAssertEqual(onDisk, .person(Person(born: 1990, sex: "female")))
        XCTAssertGreaterThanOrEqual(changes, 3)
        XCTAssertNil(keeper.set("health.sex", to: .string(""), healthOn: true), "Not set clears it")
        settle(keeper)
        XCTAssertEqual(onDisk, .person(Person(born: 1990)))
    }

    func testAValueTheRowDoesNotTakeOrHealthOffWritesNothing() {
        let keeper = keeper()
        keeper.read(.person(Person()))
        XCTAssertEqual(keeper.set("health.sex", to: .string("female"), healthOn: false), "Needs health")
        XCTAssertNotNil(keeper.set("health.born", to: .string("90"), healthOn: true))
        XCTAssertNotNil(keeper.set("health.sex", to: .bool(true), healthOn: true))
        settle(keeper)
        XCTAssertEqual(keeper.person, Person())
        XCTAssertEqual(onDisk, .person(Person()), "no file")
    }

    func testAnOlderConfigsFactsMoveInAndAnEditMeanwhileIsKept() {
        let keeper = keeper()
        var stripped = 0
        keeper.stripConfig = { stripped += 1; return nil }
        keeper.read(.person(Person(sex: "male")))
        queue.suspend()
        keeper.moveOutOfConfig(born: 1990, hand: "left")
        XCTAssertEqual(keeper.person, Person(born: 1990, sex: "male", hand: "left"))
        // An edit while the move is still sealing builds on the moved facts.
        XCTAssertNil(keeper.set("health.typing", to: .string("touch"), healthOn: true))
        keeper.moveOutOfConfig(born: 1990, hand: "left")
        queue.resume()
        settle(keeper)
        XCTAssertEqual(stripped, 1, "the config is rewritten once, after the facts are sealed")
        XCTAssertEqual(onDisk, .person(Person(born: 1990, sex: "male", hand: "left", typing: "touch")))
        // Nothing left in the config to move: nothing happens.
        keeper.moveOutOfConfig(born: nil, hand: "")
        settle(keeper)
        XCTAssertEqual(stripped, 1)
    }

    func testAWriteTheDeletionOvertookNeverBringsTheFactsBack() {
        let keeper = keeper()
        keeper.read(.person(Person()))
        queue.suspend()
        XCTAssertNil(keeper.set("health.sex", to: .string("female"), healthOn: true))
        // The record is deleted while that write still waits its turn.
        keeper.forget()
        queue.resume()
        settle(keeper)
        XCTAssertEqual(keeper.person, Person())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Person.file).path),
                       "the facts did not come back into the record that replaced the deleted one")
    }
}
