import XCTest
@testable import LodestarCore

/// Replacing one address with another, and what the old one says
/// afterwards.
///
/// The coach exists to make a hand faster, and it cannot do that while the
/// habit it argued against still works. Grossman et al. (CHI 2007) put
/// numbers on it: with both paths open, 28.9% of users reached expert use
/// and half of them never transitioned at all; with the old path closed,
/// 72.8%, and every participant learned. So an accepted supersede removes
/// the old address in the same write that binds the new one.
///
/// What the old address then says is a separate question with a separate
/// answer. It is not missing, it moved, and telling the user that is not
/// about teaching — the block does the teaching — but about an intended
/// change not being indistinguishable from a bug, at the exact moment the
/// user has just extended trust.
final class SupersedeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func accepted(old: String, new: String,
                          kind: Recommendation.Kind = .shorten) -> Observations {
        var o = Observations()
        o.ledger = [Observations.LedgerEntry(
            id: "\(kind.rawValue):\(old)", kind: kind.rawValue, target: old,
            chain: new, predictedSecondsPerWeek: 100, firstOfferedWeek: 2955,
            lastOfferedWeek: 2955, offers: 1, status: "accepted",
            acceptedWeek: 2955)]
        return o
    }

    /// The week the fixtures accept in, so age is stated rather than
    /// inherited from whenever the suite happens to run.
    private var acceptedAt: Date { weekStart(2955) }
    private func weekStart(_ week: Int) -> Date {
        Date(timeIntervalSince1970: Double(week) * 604_800)
    }

    // MARK: - The ledger is the tombstone

    func testAnAcceptedSupersedeNamesWhereTheAddressWent() {
        let o = accepted(old: "b x", new: "x")
        XCTAssertEqual(Coach.supersededBy(observations: o, letters: ["b", "x"], now: acceptedAt), "X")
    }

    func testAnAddressThatWasNeverBoundHasNotMoved() {
        let o = accepted(old: "b x", new: "x")
        XCTAssertNil(Coach.supersededBy(observations: o, letters: ["q", "z"], now: acceptedAt))
    }

    /// An offer that was made and not taken leaves the old address exactly
    /// where it was, so there is nothing to redirect to.
    func testAnUnansweredOfferIsNotARedirect() {
        var o = accepted(old: "b x", new: "x")
        o.ledger[0].status = "offered"
        XCTAssertNil(Coach.supersededBy(observations: o, letters: ["b", "x"], now: acceptedAt))
    }

    func testADeclinedOfferIsNotARedirect() {
        var o = accepted(old: "b x", new: "x")
        o.ledger[0].status = "never"
        XCTAssertNil(Coach.supersededBy(observations: o, letters: ["b", "x"], now: acceptedAt))
    }

    /// A bind adds an address without replacing one, so its accepted entry
    /// must never be read as a redirect — its `target` is an app name, not
    /// a chain, and the two could collide.
    func testAPlainBindIsNotARedirect() {
        var o = accepted(old: "b x", new: "x", kind: .bind)
        o.ledger[0].kind = Recommendation.Kind.bind.rawValue
        XCTAssertNil(Coach.supersededBy(observations: o, letters: ["b", "x"], now: acceptedAt))
    }

    /// The generalisation the whole shape exists for: a replacement need
    /// not be shorter. A same-length swap that stops fighting the hand
    /// supersedes exactly as much.
    func testASameLengthRebindAlsoSupersedes() {
        let o = accepted(old: "v", new: "x", kind: .rebind)
        XCTAssertEqual(Coach.supersededBy(observations: o, letters: ["v"], now: acceptedAt), "X")
        XCTAssertTrue(Recommendation.Kind.rebind.supersedes)
        XCTAssertTrue(Recommendation.Kind.shorten.supersedes)
    }

    func testKindsThatAddOrRemoveDoNotSupersede() {
        for kind: Recommendation.Kind in [.bind, .retire, .breath, .route,
                                          .meetings, .nudge] {
            XCTAssertFalse(kind.supersedes, "\(kind) replaces nothing")
        }
    }

    // MARK: - When it stops saying so

    /// The primary gate, and the honest one: the hand arrived. Same bent
    /// curve the learning slot waits on, so "learned" means one thing in
    /// this codebase rather than two.
    func testTheRedirectRetiresOnceTheNewAddressCurveBends() {
        var o = accepted(old: "b x", new: "x")
        var record = Observations.AddressRecord()
        for _ in 0..<Coach.bentCompletions { record.trigger.add(0.2) }
        o.addresses["x"] = record
        XCTAssertNil(Coach.supersededBy(observations: o, letters: ["b", "x"],
                                        now: acceptedAt))
    }

    /// One short of bent is still mid-transition.
    func testTheRedirectStandsWhileTheCurveIsStillBending() {
        var o = accepted(old: "b x", new: "x")
        var record = Observations.AddressRecord()
        for _ in 0..<(Coach.bentCompletions - 1) { record.trigger.add(0.2) }
        o.addresses["x"] = record
        XCTAssertEqual(Coach.supersededBy(observations: o, letters: ["b", "x"],
                                          now: acceptedAt), "X")
    }

    /// The backstop, for an address so rarely used the curve never bends.
    /// Past it the redirect outlives anyone's memory of agreeing to it.
    func testTheRedirectExpiresOnTheCutoffEvenIfTheCurveNeverBent() {
        let o = accepted(old: "b x", new: "x")
        let justInside = weekStart(2955 + Coach.supersedeCutoffWeeks - 1)
        let past = weekStart(2955 + Coach.supersedeCutoffWeeks)
        XCTAssertEqual(Coach.supersededBy(observations: o, letters: ["b", "x"],
                                          now: justInside), "X")
        XCTAssertNil(Coach.supersededBy(observations: o, letters: ["b", "x"],
                                        now: past))
    }

    /// An accept with no date cannot be aged, and that is not grounds for
    /// going quiet — the curve still governs it.
    func testAnUndatedAcceptIsGovernedByTheCurveAlone() {
        var o = accepted(old: "b x", new: "x")
        o.ledger[0].acceptedWeek = nil
        XCTAssertEqual(Coach.supersededBy(observations: o, letters: ["b", "x"],
                                          now: weekStart(2955 + 200)), "X")
    }

    // MARK: - What the old address does when it is pressed

    private func core(graph: [String: GraphResolution],
                      superseded: [String: String] = [:])
        -> (EngineCore, WorldStub) {
        let world = WorldStub()
        world.graph = graph
        world.superseded = superseded
        return (EngineCore(), world)
    }

    /// The case that actually happens. `lode B X` with `b x` removed is a
    /// *mid-traversal* miss, not a first-letter one: `b` still resolves,
    /// so without this the user is left sitting inside the `b` chain,
    /// waiting to type a letter that is never coming back.
    func testASupersededAddressLeavesTheChainInsteadOfStranding() {
        var (engine, world) = core(graph: ["b": .deeper, "bx": .miss],
                                   superseded: ["bx": "X"])
        _ = engine.keyDown(key: "b", held: true, shift: false, world: world)
        let effects = engine.keyDown(key: "x", held: true, shift: false, world: world)

        XCTAssertEqual(effects, [.hideGuide, .flash("⌖ lode B X moved to lode X")])
        XCTAssertEqual(engine.state, .idle,
                       "a moved address ends the gesture, it does not park you in a mode")
    }

    /// An address that was never bound still reports honestly, and still
    /// keeps the user in the chain so a typo can be corrected.
    func testAnOrdinaryMissIsUnchanged() {
        var (engine, world) = core(graph: ["b": .deeper, "bq": .miss])
        _ = engine.keyDown(key: "b", held: true, shift: false, world: world)
        let effects = engine.keyDown(key: "q", held: true, shift: false, world: world)

        XCTAssertEqual(effects, [.showGuide(kind: .graph, letters: ["b"], deleting: false,
                                            note: "✕ B Q is not on the graph")],
                       "a typo mid-traversal stays put and shows the way out")
        XCTAssertEqual(engine.state, .chain(kind: .graph, letters: ["b"], deleting: false))
    }

    /// A first-letter miss on a superseded address redirects too — the
    /// same fact, reached by a shorter road.
    func testAFirstLetterMissRedirectsAsWell() {
        var (engine, world) = core(graph: ["v": .miss], superseded: ["v": "X"])
        let effects = engine.keyDown(key: "v", held: true, shift: false, world: world)

        XCTAssertEqual(effects, [.hideGuide, .flash("⌖ lode V moved to lode X")])
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - The write

    /// The ordering hazard. A replacement need not be shorter, so the two
    /// addresses can share a prefix. Binding the new one first would put
    /// it inside a branch the delete then takes with it, and the accept
    /// would silently leave the user with neither address.
    func testSupersedingIntoAPrefixOfTheOldAddressKeepsTheNewOne() throws {
        let root: [String: ConfigValue] = ["graph": .table(["x": .string("Brave")])]
        let pruned = try GraphJsonEditor.deletingPath(["x"], in: root)
        let bound = try GraphJsonEditor.addingPath(["x", "y"], target: "Brave", in: pruned)
        let graph = try XCTUnwrap(bound["graph"]?.table)
        let branch = try XCTUnwrap(graph["x"]?.table)
        XCTAssertEqual(branch["y"]?.string, "Brave")
    }

    /// Proof the ordering matters rather than being a precaution: with the
    /// add first, the new address is either refused outright or swallowed
    /// by the delete that follows it.
    func testTheOtherOrderLosesTheNewAddress() {
        let root: [String: ConfigValue] = ["graph": .table(["x": .string("Brave")])]
        var survived = false
        if let bound = try? GraphJsonEditor.addingPath(["x", "y"], target: "Brave", in: root),
           let pruned = try? GraphJsonEditor.deletingPath(["x"], in: bound) {
            survived = pruned["graph"]?.table?["x"]?.table?["y"]?.string == "Brave"
        }
        XCTAssertFalse(survived, "add-then-delete must not be what ships")
    }

    /// The plain case, and the reason the delete never orphans a stub:
    /// removing the last child takes the parent with it.
    func testSupersedingADeepAddressPrunesAnEmptyParent() throws {
        let root: [String: ConfigValue] = [
            "graph": .table(["b": .table(["x": .string("brave:xonar")])]),
        ]
        let pruned = try GraphJsonEditor.deletingPath(["b", "x"], in: root)
        let bound = try GraphJsonEditor.addingPath(["x"], target: "brave:xonar", in: pruned)
        let graph = try XCTUnwrap(bound["graph"]?.table)
        XCTAssertNil(graph["b"], "a parent left with no children is not kept as a stub")
        XCTAssertEqual(graph["x"]?.string, "brave:xonar")
    }

    /// Siblings are untouched: superseding `b x` must not disturb `b d`.
    func testSupersedingLeavesSiblingsAlone() throws {
        let root: [String: ConfigValue] = [
            "graph": .table(["b": .table(["x": .string("brave:xonar"),
                                          "d": .string("brave:default")])]),
        ]
        let pruned = try GraphJsonEditor.deletingPath(["b", "x"], in: root)
        let bound = try GraphJsonEditor.addingPath(["x"], target: "brave:xonar", in: pruned)
        let graph = try XCTUnwrap(bound["graph"]?.table)
        XCTAssertEqual(graph["b"]?.table?["d"]?.string, "brave:default")
        XCTAssertNil(graph["b"]?.table?["x"])
        XCTAssertEqual(graph["x"]?.string, "brave:xonar")
    }

    // MARK: - What the chip promises

    /// The user is agreeing to lose an address, and the chip has to say
    /// so. "Bind it" describes an addition, which is what a supersede is
    /// not.
    func testTheChipSaysTheAddressMovesRatherThanIsAdded() {
        let rec = Recommendation(
            kind: .shorten, target: "b x", detail: "earned a letter",
            secondsPerWeek: 169, probability: 0.97, evidence: [],
            display: "Brave (Xonar)",
            edit: .supersede(old: ["b", "x"], new: ["x"], target: "brave:xonar"))
        let chip = Coach.chip(for: rec, observations: Observations())
        XCTAssertEqual(chip.headline, "lode X → Brave (Xonar)")
        XCTAssertTrue(chip.footer.contains("move it"), "got \(chip.footer)")
        XCTAssertFalse(chip.footer.contains("bind it"))
    }

    /// A plain bind adds and takes nothing, so it keeps the old verb.
    func testAPlainBindStillSaysBind() {
        let rec = Recommendation(
            kind: .bind, target: "facetime", detail: "searched often",
            secondsPerWeek: 45, probability: 0.95, evidence: [],
            edit: .bindTarget(chain: ["f"], target: "facetime"))
        let chip = Coach.chip(for: rec, observations: Observations())
        XCTAssertTrue(chip.footer.contains("bind it"), "got \(chip.footer)")
    }

    // MARK: - The ledger records the address being learned

    /// `slotBusy` watches the new address's curve bend, and `supersededBy`
    /// reads the same field to know where the old one went. Both break if
    /// a supersede stamps the address being given up.
    func testTheLedgerKeepsTheNewAddressNotTheOldOne() {
        let rec = Recommendation(
            kind: .shorten, target: "b x", detail: "earned a letter",
            secondsPerWeek: 100, probability: 0.97, evidence: [],
            edit: .supersede(old: ["b", "x"], new: ["x"], target: "brave:xonar"))
        var event = ObservationEvent(t: start, kind: .coach)
        event.action = "offered"
        event.rec = rec.kind.rawValue
        event.app = rec.target
        if case .supersede(_, let new, _)? = rec.edit {
            event.address = Observations.key(new)
        }
        var o = Observations()
        o.apply(event)
        XCTAssertEqual(o.ledger.first?.chain, "x",
                       "the chain is the address being learned, never the one retired")
    }
}
