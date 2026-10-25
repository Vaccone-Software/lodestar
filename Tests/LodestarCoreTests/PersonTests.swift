import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The facts about you are sealed with the health record, take only the
/// values their rows offer, and move in from an older config without
/// overwriting what was set since.
final class PersonTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("person-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEachRowTakesOnlyItsOwnValues() throws {
        var person = Person()
        person = try person.setting("health.born", to: " 1990 ")
        person = try person.setting("health.sex", to: "female")
        person = try person.setting("health.hand", to: "left")
        person = try person.setting("health.typing", to: "touch")
        XCTAssertEqual(person, Person(born: 1990, sex: "female", hand: "left", typing: "touch"))
        XCTAssertThrowsError(try person.setting("health.born", to: "90"))
        XCTAssertThrowsError(try person.setting("health.born", to: "1850"))
        XCTAssertThrowsError(try person.setting("health.sex", to: "f"))
        XCTAssertThrowsError(try person.setting("health.typing", to: "hunt"))
        XCTAssertThrowsError(try person.setting("observations.health", to: "true"))
        let cleared = try person.setting("health.born", to: "").setting("health.hand", to: "")
        XCTAssertNil(cleared.born)
        XCTAssertEqual(cleared.hand, "")
        XCTAssertEqual(cleared.sex, "female", "clearing one fact leaves the others")
    }

    func testTheFileLeavesOutWhatWasNotGiven() {
        XCTAssertEqual(String(decoding: Person().encoded(), as: UTF8.self), "{}")
        let person = Person(born: 1990, hand: "right")
        XCTAssertEqual(String(decoding: person.encoded(), as: UTF8.self), #"{"born":1990,"hand":"right"}"#)
        XCTAssertEqual(Person.decoded(person.encoded()), person)
        // A value this build does not take reads as not given.
        XCTAssertEqual(Person.decoded(Array(#"{"born":1990,"sex":"robot","extra":1}"#.utf8)), Person(born: 1990))
        XCTAssertNil(Person.decoded(Array("not json".utf8)))
    }

    func testAnOlderConfigFillsOnlyWhatIsNotSet() {
        let set = Person(born: 1985, sex: "male")
        XCTAssertEqual(set.movingIn(born: 1990, hand: "left"), Person(born: 1985, sex: "male", hand: "left"))
        XCTAssertEqual(Person().movingIn(born: nil, hand: "sideways"), Person(), "a hand the row does not offer stays out")
    }

    func testTheFactsAreSealedUnderTheHealthKey() throws {
        let vault = SealedFixture.vault(directory)
        let file = PersonFile(directory: directory, ring: vault.ring(.health))
        XCTAssertEqual(file.read(), .person(Person()), "no file reads as nothing given")
        XCTAssertEqual(file.write(Person(born: 1990, sex: "intersex", hand: "either", typing: "other")), .written)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(Person.file))
        XCTAssertTrue(Sealing.isSealed([UInt8](bytes)))
        XCTAssertNil(bytes.range(of: Data("1990".utf8)), "no plaintext on disk")
        XCTAssertEqual(file.read(), .person(Person(born: 1990, sex: "intersex", hand: "either", typing: "other")))
        XCTAssertTrue(RecordFiles.sealed(of: .health, in: directory.path, fileSystem: PosixFileSystem()).contains(Person.file),
                      "it belongs to the health record: set aside, exported and deleted with it")
    }
}
