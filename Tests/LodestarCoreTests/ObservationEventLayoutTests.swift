import XCTest
@testable import LodestarCore

/// An event is a thousand bytes and more of columns that most kinds never
/// fill, and a ring read whole holds one per line. These tests pin what
/// must not move when its largest columns are kept off its own body: its
/// size, the bytes it encodes to, and that a copy is still a copy.
final class ObservationEventLayoutTests: XCTestCase {
    /// An event with every column set, to values no other column shares.
    static func full() -> ObservationEvent {
        let start = Date(timeIntervalSince1970: 1_790_000_000.25)
        var e = ObservationEvent(t: start, kind: .window)
        e.chain = ["b", "p"]; e.gaps = [0.5, 0.25]; e.peeked = true; e.hover = 1.5; e.pressed = "g"
        e.app = "Xcode"; e.category = "dev"; e.declaredCategory = "public.app-category.developer-tools"
        e.route = "graph"; e.apps = ["Xcode", "Slack"]; e.typed = 3; e.queryPrefix = "xc"; e.rank = 2
        e.listLength = 9; e.openToFirstKey = 0.75; e.openToCommit = 2.5; e.verb = "scroll"
        e.host = "example.com"; e.profile = "brave:Work"; e.source = "typed"; e.row = "link"
        e.address = "b p"; e.change = "added"; e.epoch = 4; e.action = "offered"; e.rec = "bind"
        e.lead = -30; e.seconds = 42.5; e.keys = 311; e.backspaces = 12; e.bsRuns = [3, 2, 1]
        e.bsRunKeys = [3, 5, 7]; e.clicks = 20; e.scrolls = 5; e.activeMinutes = 9; e.ikN = 100
        e.ikSum = 18.5; e.ikSumSq = 3.75; e.trips = 4; e.roles = ["text": 3, "button": 1]
        var pointer = PointerMoments()
        pointer.n = 7; pointer.travelSum = 412.5; pointer.travelSumSq = 30_000.25; pointer.settleSum = 3.5
        pointer.homingN = 2; pointer.homingSum = 1.25; pointer.pressN = 7; pointer.pressSum = 0.875
        var kin = KinMoments()
        kin.n = 7; kin.secondsSum = 2.5; kin.rateSum = 11.5; kin.bandsN = 3; kin.lowSum = 1.5
        pointer.kin = kin
        e.pointer = pointer
        e.scrollSeconds = 6.5; e.pages = 8; e.ends = 2; e.aims = 3; e.aimsLanded = 2; e.aimsAway = 1
        e.words = 14; e.switches = 6; e.pointerActs = 5; e.firstWord = 1.75; e.matches = 11
        e.visible = 8; e.recents = 20; e.depth = 6; e.closed = "escape"; e.after = "paste"
        e.pulled = true; e.pointerOn = false; e.warm = true; e.editing = "standard"; e.peakDb = -31.5
        e.holdN = 100; e.holdSum = 9.5; e.holdSumSq = 0.95
        var hold = Histogram(); hold.add(0.09); hold.add(0.12); hold.add(0.3)
        e.holdHist = hold
        var rhythm = Histogram(); rhythm.add(0.15); rhythm.add(0.2)
        e.ikHist = rhythm
        e.ikTailN = 3; e.ikTailSum = 4.5; e.boutIndex = 2; e.boutSeconds = 1800.5
        var window = WindowStats(start: start)
        window.seconds = 88.5; window.presses = 400; window.typing = 380; window.valid = true
        for hold in [0.08, 0.09, 0.1, 0.11] { window.hold.add(hold) }
        window.holdQ = [0.06, 0.07, 0.08, 0.09, 0.1, 0.12, 0.14]; window.holdCDF = [90, 300, 360, 380]
        window.outliers = 4; window.fluct.add(0.1); window.fluctQ = [-0.1, 0, 0.1]
        window.flight.add(0.02); window.overlap.add(0.01); window.overlapN = 5; window.latency.add(0.2)
        window.left.hold.add(0.09); window.left.q = [0.08, 0.09, 0.1]
        window.right.hold.add(0.1); window.right.q = [0.09, 0.1, 0.11]
        window.ll.add(latency: 0.2, flight: 0.05); window.lr.add(latency: 0.21, flight: 0.06)
        window.rl.add(latency: 0.22, flight: 0.07); window.rr.add(latency: 0.23, flight: 0.08)
        window.shift = 5; window.chord = 2; window.gesture = 1; window.lens = 1; window.repeated = 3
        window.unseen = 1; window.keyboardTypes = ["builtin": 300, "usb": 100]
        window.fingers = [10, 20, 30, 40, 50, 60, 70, 80]; window.modifiers = 9; window.struck = 21
        var modifierHold = Moments(); modifierHold.add(0.4)
        window.modifierHold = modifierHold
        window.app = "Xcode"; window.category = "dev"; window.declaredCategory = "tools"; window.role = "AXTextArea"
        window.keyboards = ["Adv360"]; window.pointers = ["Magic Trackpad"]; window.power = "battery"
        window.screens = 2
        let display = DisplayInfo(width: 3456, height: 2234, scale: 2, mmWidth: 345.5, mmHeight: 223.5, main: true)
        window.displays = [display]; window.lid = false; window.layout = "com.apple.keylayout.US"
        window.dictation = false; window.tz = -300; window.boutSeconds = 900.5
        e.window = window
        e.voice = VoiceStats(seconds: 12.5, speechSeconds: 9.5, voicedSeconds: 6.5, pauses: Moments(),
                             f0: Moments(), f0SpreadSemitones: 3.5, intensity: Moments(), jitter: 0.015,
                             shimmer: 0.05, cyclePairs: 300, hnr: Moments(), speechRate: 2.75,
                             articulationRate: 3.5, words: 31, mic: "built-in", mixed: false)
        e.keyboards = ["Adv360", "Built-in"]
        e.jitterN = 50; e.jitterSum = 0.5; e.jitterSumSq = 0.01; e.tapResets = 1; e.fixN = 4; e.fixSum = 2.5
        e.fixSumSq = 2.0; e.scrollPrecise = 4; e.scrollMomentum = 1; e.clicksPosted = 2
        e.pointers = ["Magic Trackpad"]; e.lid = true
        e.era = EraInfo(appVersion: "0.55.0", keySchema: 3, pointerSchema: 2, layout: "com.apple.keylayout.US",
                        keyboards: ["Adv360"], pointers: ["Magic Trackpad"], displays: [display],
                        settings: InputSettings(keyRepeat: 2, initialKeyRepeat: 25, mouseScaling: 0.5,
                                                trackpadScaling: 1, naturalScroll: true, tapToClick: false,
                                                forceClick: true),
                        lid: false, fingerMap: "a=1", reportIntervals: ["Adv360": .microseconds(1000)],
                        exactKeyboards: true, reason: "changed")
        e.blind = BlindSpan(kind: .tapOff, end: start.addingTimeInterval(60), startBound: true, endBound: false,
                            resolution: 0.5)
        return e
    }

    private func encoded(_ event: ObservationEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    private func decoded(_ data: Data) throws -> ObservationEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ObservationEvent.self, from: data)
    }

    /// 3,056 bytes when every column sat on the body of the event.
    func testAnEventIsAKilobyteAtMost() {
        XCTAssertLessThanOrEqual(MemoryLayout<ObservationEvent>.stride, 1_024)
    }

    /// Captured from the event as it was, with every column stored in it:
    /// 90 keys, 5,463 bytes. The line a ring holds is the line it always
    /// held, so an older build reads what this one writes and the reverse.
    func testAnEventWithEveryColumnSetEncodesToTheBytesItAlwaysDid() throws {
        let data = try encoded(Self.full())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["action", "activeMinutes", "address", "after", "aims", "aimsAway", "aimsLanded", "app", "apps", "backspaces", "blind", "boutIndex", "boutSeconds", "bsRunKeys", "bsRuns", "category", "chain", "change", "clicks", "clicksPosted", "closed", "declaredCategory", "depth", "editing", "ends", "epoch", "era", "firstWord", "fixN", "fixSum", "fixSumSq", "gaps", "holdHist", "holdN", "holdSum", "holdSumSq", "host", "hover", "ikHist", "ikN", "ikSum", "ikSumSq", "ikTailN", "ikTailSum", "jitterN", "jitterSum", "jitterSumSq", "keyboards", "keys", "kind", "lead", "lid", "listLength", "matches", "openToCommit", "openToFirstKey", "pages", "peakDb", "peeked", "pointer", "pointerActs", "pointerOn", "pointers", "pressed", "profile", "pulled", "queryPrefix", "rank", "rec", "recents", "roles", "route", "row", "scrollMomentum", "scrollPrecise", "scrollSeconds", "scrolls", "seconds", "source", "switches", "t", "tapResets", "trips", "typed", "verb", "visible", "voice", "warm", "window", "words"], "every column, once")
        XCTAssertEqual(data.count, 5_463)
        XCTAssertEqual(Digest.sha256([UInt8](data)).map { String(format: "%02x", $0) }.joined(),
                       "cc1213d41b3f8fce74115f8618a91ea238354b763c65a8d362846cfb01f79dfd")
    }

    func testAnEventWithEveryColumnSetReadsBackAsItWas() throws {
        let event = Self.full()
        let back = try decoded(try encoded(event))
        XCTAssertEqual(back, event)
        XCTAssertEqual(try encoded(back), try encoded(event))
        XCTAssertEqual(back.window?.presses, 400)
        XCTAssertEqual(back.voice?.words, 31)
        XCTAssertEqual(back.pointer?.kin?.n, 7)
        XCTAssertEqual(back.era?.settings.keyRepeat, 2)
        XCTAssertEqual(back.blind?.blindKind, .tapOff)
        XCTAssertEqual(back.holdN, 100)
        XCTAssertEqual(back.clicksPosted, 2)
        XCTAssertEqual(back.ikSumSq, 3.75)
    }

    /// An event is a value: a copy that is changed is a copy, and the one it
    /// came from is as it was, whichever column is touched and from whichever
    /// side.
    func testACopyThatIsChangedLeavesTheOriginalAlone() {
        let pristine = Self.full()
        var original = Self.full()
        var copy = original
        copy.window?.presses += 1
        copy.voice = nil
        copy.pointer?.n = 99
        copy.era?.reason = "keyboard"
        copy.blind = nil
        copy.holdN = 1
        copy.jitterSum = nil
        copy.clicksPosted = 50
        XCTAssertEqual(original, pristine)
        XCTAssertEqual(copy.window?.presses, 401)
        XCTAssertNil(copy.voice)
        XCTAssertEqual(copy.pointer?.n, 99)
        XCTAssertEqual(copy.era?.reason, "keyboard")
        XCTAssertNil(copy.blind)
        XCTAssertEqual(copy.holdN, 1)
        XCTAssertNil(copy.jitterSum)
        XCTAssertEqual(copy.clicksPosted, 50)
        XCTAssertEqual(copy.ikN, 100, "what was not touched is as it was")

        // And the other way: the original changed after it was copied.
        let kept = original
        original.window?.presses = 7
        original.holdSum = 77
        original.fixN = nil
        XCTAssertEqual(kept, pristine)
        XCTAssertEqual(original.window?.presses, 7)
        XCTAssertEqual(original.holdSum, 77)
    }

    func testAColumnSetAndThenClearedLeavesAnEventEqualToOneNeverSet() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var event = ObservationEvent(t: t, kind: .pulse)
        event.holdN = 3
        event.fixSum = 0.5
        event.window = WindowStats(start: t)
        XCTAssertNotEqual(event, ObservationEvent(t: t, kind: .pulse))
        event.holdN = nil
        event.fixSum = nil
        event.window = nil
        XCTAssertEqual(event, ObservationEvent(t: t, kind: .pulse), "a group with nothing in it is no group")
        XCTAssertEqual(try encoded(event), try encoded(ObservationEvent(t: t, kind: .pulse)))
        event.ikN = nil
        XCTAssertEqual(event, ObservationEvent(t: t, kind: .pulse), "clearing what was never set sets nothing")
    }

    /// A line another build wrote: some columns this one has, one it does
    /// not, none that is out of line set to anything but what the line says.
    func testALineFromAnotherBuildReadsColumnForColumn() throws {
        let line = Data("""
        {"kind":"pulse","t":1700000000,"holdN":100,"holdSum":9.5,"jitterN":3,"keys":120,"ikN":90,\
        "futureColumn":{"a":[1,2]},"keyboards":["Adv360"],"blind":{"kind":"asleep","end":1700000090}}
        """.utf8)
        let event = try decoded(line)
        XCTAssertEqual(event.kind, .pulse)
        XCTAssertEqual(event.holdN, 100)
        XCTAssertEqual(event.holdSum, 9.5)
        XCTAssertEqual(event.jitterN, 3)
        XCTAssertEqual(event.ikN, 90)
        XCTAssertEqual(event.keys, 120)
        XCTAssertNil(event.holdSumSq, "a column the line does not carry is unset")
        XCTAssertNil(event.window)
        XCTAssertEqual(event.blind?.kind, "asleep")
        XCTAssertEqual(event.keyboards, ["Adv360"])
        let bare = try decoded(Data(#"{"kind":"focus","t":1700000000,"app":"Slack"}"#.utf8))
        XCTAssertEqual(bare.app, "Slack")
        XCTAssertEqual(try encoded(bare), Data(#"{"app":"Slack","kind":"focus","t":1700000000}"#.utf8),
                       "an event with nothing out of line writes only what is set")
    }

    /// The event's coding is written out by hand (its large columns live
    /// behind pointers, and one group of them behind a single pointer), so a
    /// column added to the struct is not coded until it is added to
    /// `CodingKeys`, `init(from:)` and `encode(to:)` as well: it would be
    /// dropped on its way to disk and nothing would say so. This count is the
    /// tripwire. When it fails, add the new column to all three and to the
    /// every-column fixture above, then change the count.
    func testAColumnAddedToTheEventMustBeAddedToItsCoding() {
        let stored = Mirror(reflecting: ObservationEvent(t: Date(timeIntervalSince1970: 0), kind: .focus)).children.count
        XCTAssertEqual(stored, 71, "stored properties of ObservationEvent: 65 columns held in the struct and 6 pointers to the 25 that are not")
    }
}
