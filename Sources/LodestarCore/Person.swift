import Foundation

/// What only the person can say about themselves, for the health record:
/// the year they were born, their sex, the hand they write with, and
/// whether they touch type. Age and sex are the first things any reading
/// of the hands is adjusted for, fine motor signs are often one sided, and
/// the finger column assumes a touch typist's fingers, so a reader needs
/// to know when it does not hold.
///
/// Kept sealed beside the health record (`person.json`, under the health
/// key), never in the config: the config is plaintext, backed up, and its
/// history keeps every value it ever held. It goes where the health record
/// goes: exported with it, deleted with it. Every field is optional, and
/// empty means not given.
public struct Person: Equatable, Sendable {
    public var born: Int?
    public var sex = ""
    public var hand = ""
    public var typing = ""

    public init(born: Int? = nil, sex: String = "", hand: String = "", typing: String = "") {
        self.born = born
        self.sex = sex
        self.hand = hand
        self.typing = typing
    }

    public static let file = "person.json"

    public static let sexes = ["female", "male", "intersex"]
    public static let hands = ["left", "right", "either"]
    public static let typings = ["touch", "other"]

    /// The Settings rows' paths. `health.born` and `health.hand` were config
    /// keys until the facts moved here; the rows kept their names.
    public static let paths = ["health.born", "health.sex", "health.hand", "health.typing"]

    /// The config keys the facts were once written under, which the app
    /// moves here when it finds them (`movingIn`) and the config history
    /// never keeps.
    public static let configPaths: [[String]] = [["health", "born"], ["health", "hand"]]

    public var isEmpty: Bool { self == Person() }

    /// A year as the person typed it: four digits from 1900 to 2100, nil
    /// for anything else.
    public static func year(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard digits.count == 4, let year = Int(digits), (1900...2100).contains(year) else { return nil }
        return year
    }

    /// The facts with one Settings row's value written in. Empty clears a
    /// field. Throws the line the row shows when the value is not one the
    /// field takes.
    public func setting(_ path: String, to text: String) throws -> Person {
        var next = self
        let value = text.trimmingCharacters(in: .whitespaces)
        func choice(_ allowed: [String]) throws -> String {
            guard value.isEmpty || allowed.contains(value) else {
                throw Problem(description: "\(path): \"\(value)\" is not one of \(allowed.joined(separator: ", "))")
            }
            return value
        }
        switch path {
        case "health.born":
            if value.isEmpty {
                next.born = nil
            } else if let year = Self.year(value) {
                next.born = year
            } else {
                throw Problem(description: "Born takes a year, four digits")
            }
        case "health.sex": next.sex = try choice(Self.sexes)
        case "health.hand": next.hand = try choice(Self.hands)
        case "health.typing": next.typing = try choice(Self.typings)
        default: throw Problem(description: "\(path) is not a fact about you")
        }
        return next
    }

    /// The facts with what an older config held filled in, where nothing is
    /// set already: what is here was written later than any config line.
    public func movingIn(born: Int?, hand: String) -> Person {
        var next = self
        if next.born == nil { next.born = born }
        if next.hand.isEmpty, Self.hands.contains(hand) { next.hand = hand }
        return next
    }

    public struct Problem: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    // MARK: The file

    /// The facts as the file keeps them: sorted keys, empty fields left out.
    public func encoded() -> [UInt8] {
        var object: [String: Any] = [:]
        if let born { object["born"] = born }
        if !sex.isEmpty { object["sex"] = sex }
        if !hand.isEmpty { object["hand"] = hand }
        if !typing.isEmpty { object["typing"] = typing }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Array(data)
    }

    /// The facts from the file's bytes. A field the file holds that is not
    /// one this build takes reads as not given, never as a failure.
    public static func decoded(_ bytes: [UInt8]) -> Person? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return nil }
        var person = Person()
        if let born = object["born"] as? Int, (1900...2100).contains(born) { person.born = born }
        if let sex = object["sex"] as? String, sexes.contains(sex) { person.sex = sex }
        if let hand = object["hand"] as? String, hands.contains(hand) { person.hand = hand }
        if let typing = object["typing"] as? String, typings.contains(typing) { person.typing = typing }
        return person
    }
}

/// `person.json`, sealed under the health key.
public struct PersonFile: Sendable {
    public let stored: SealedValueFile

    public init(directory: URL = Paths.data, ring: Vault.Ring) {
        stored = SealedValueFile(url: directory.appendingPathComponent(Person.file), name: Person.file, ring: ring)
    }

    public enum Read: Equatable {
        case person(Person)
        /// Something is on disk that this read could not give back: the key
        /// cannot be asked for, or the file will not open. Nothing may be
        /// written over it.
        case unavailable(String)
    }

    /// **Not for the main thread**: the first read may ask the keychain.
    public func read() -> Read {
        switch stored.read() {
        case .absent: return .person(Person())
        case .value(let bytes, _):
            guard let person = Person.decoded(bytes) else { return .unavailable("person.json is not a record of facts") }
            return .person(person)
        case .unavailable: return .unavailable("the health key cannot be asked for")
        case .unreadable(let why): return .unavailable(why)
        }
    }

    /// **Not for the main thread**: the first write may make the key.
    public func write(_ person: Person) -> SealedValueFile.Written {
        stored.write(person.encoded())
    }
}
