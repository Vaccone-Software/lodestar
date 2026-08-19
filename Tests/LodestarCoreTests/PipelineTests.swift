import XCTest
@testable import LodestarCore

/// The whole pipeline, end to end: a month of synthetic life recorded
/// through the real store, flushed to real files, read back, and fed to
/// every model. This is the test that catches the seams the unit tests
/// cannot — an event the log writes but the view ignores, a model that
/// chokes on the shape real accumulation produces.
final class PipelineTests: XCTestCase {
    private var directory: URL!
    /// Four weeks ago, relative to the wall clock: load() compacts the ring
    /// by age against *now*, so a fixture pinned to an absolute date would
    /// silently age out one day and starve every event-fed model — which is
    /// exactly what it did the first time this test ran. Whole seconds,
    /// because the view file and the event log serialize dates on different
    /// epochs and a fractional second rounds differently on each.
    private let start = Date(timeIntervalSince1970:
        (Date().timeIntervalSince1970 - 28 * 86_400).rounded())

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-pipeline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private struct Noise {
        private var state: UInt64 = 31
        mutating func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func normal(sd: Double) -> Double {
            let u1 = max(1e-12, uniform())
            let u2 = uniform()
            return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    func testAMonthOfLifeSurvivesTheWholeStack() throws {
        let store = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
        var noise = Noise()

        // Four weeks. Ghostty is owned; "b d" is being learned; FaceTime
        // is searched daily and has no address; github.com always lands
        // in work; ghostty and brave form a loop.
        var use = 0
        for week in 0..<4 {
            for day in 0..<7 {
                let base = start.addingTimeInterval(Double(week) * 604_800
                    + Double(day) * 86_400)
                for i in 0..<8 {
                    let at = base.addingTimeInterval(Double(i) * 3000)
                    use += 1
                    // Owned: tight and fast, an occasional lapse.
                    store.chainCompleted(["g"], gaps:
                        [exp(log(use % 19 == 0 ? 2.0 : 0.12) + noise.normal(sd: 0.15))],
                        peeked: false, at: at)
                    // Learning: an exponential curve bending down.
                    let learning = exp(log(0.35) + 1.0 * exp(-0.15 * Double(use))
                        + noise.normal(sd: 0.12))
                    store.chainCompleted(["b", "d"], gaps:
                        [learning, exp(log(0.15) + noise.normal(sd: 0.12))],
                        peeked: use < 10, at: at.addingTimeInterval(60))
                    store.focused(app: "Ghostty", at: at.addingTimeInterval(90))
                    store.focused(app: "Brave", at: at.addingTimeInterval(120))
                }
                store.reached("FaceTime", via: .searcher,
                              cost: Observations.LauncherCost(
                                  typed: 3, prefix: "fa", rank: 0, listLength: 6,
                                  openToFirstKey: 0.4,
                                  openToCommit: exp(log(1.9) + noise.normal(sd: 0.1))),
                              at: base.addingTimeInterval(40_000))
                store.reached("Ghostty", via: .graph, at: base.addingTimeInterval(41_000))
                store.webOpened(host: "github.com", profile: "brave:work",
                                source: day % 2 == 0 ? "typed" : "clicked",
                                at: base.addingTimeInterval(42_000))
                store.verbUsed("launcher", at: base.addingTimeInterval(43_000))
            }
        }
        store.chainAbandoned(["b"], hover: 3.0, at: start.addingTimeInterval(1_000_000))
        store.wrongKey(after: [], pressed: "w", at: start.addingTimeInterval(1_000_100))
        store.epochBumped(address: ["b", "d"], change: "retargeted",
                          at: start.addingTimeInterval(2_419_000))
        store.flush()

        // Read it all back through the files, as the CLI would.
        let reloaded = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
        reloaded.load()
        let o = reloaded.observations
        let events = reloaded.log.readAll()

        XCTAssertEqual(o, store.observations, "disk round trip changes nothing")
        XCTAssertGreaterThan(events.count, 1000)
        XCTAssertEqual(Observations.rebuild(from: events), o,
                       "and the log still replays to the same view")

        // Every model stands up on this data.
        let latency = LatencyModel.fit(samples: LatencyModel.samples(from: events))
        XCTAssertNotNil(latency)
        XCTAssertGreaterThan(latency?.chainSeconds(["b", "d"]) ?? 0,
                             latency?.chainSeconds(["g"]) ?? 1)

        let curve = LearningCurve.fit(observations: o)
        XCTAssertNotNil(curve, "the learner's curve is fittable")

        let mixture = RecallMixture.fit(observations: o)
        XCTAssertNotNil(mixture)
        XCTAssertGreaterThan(mixture?.ownership["g"] ?? 0, 0.7, "ghostty is owned")

        let demand = Demand.fit(weeklyCounts:
            Demand.weeklySearcherCounts(app: "facetime", events: events,
                                        now: start.addingTimeInterval(4 * 604_800)))
        XCTAssertEqual(demand?.perWeek ?? 0, 7, accuracy: 1.5, "daily searching, seen")

        XCTAssertFalse(Transitions.strongPairs(o.transitions).isEmpty)
        XCTAssertFalse(Shadow.evaluate(events: events).isEmpty)

        let activation = Activation.exact(
            uses: Activation.uses(from: events)["g"] ?? [],
            at: start.addingTimeInterval(4 * 604_800))
        XCTAssertNotNil(activation)

        // And the advisor reads the world correctly: FaceTime deserves F.
        let context = Advisor.Context(
            observations: o, events: events,
            leaves: [.init(chain: ["g"], label: "Ghostty", value: "Ghostty"),
                     .init(chain: ["b", "d"], label: "Brave (default)",
                           value: "brave:default")],
            webRoutes: [:],
            now: start.addingTimeInterval(4 * 604_800))
        let recommendations = Advisor.recommend(context)
        XCTAssertTrue(recommendations.contains { $0.kind == .bind && $0.target == "facetime" },
                      "the app searched daily with no address is the finding")
        XCTAssertTrue(recommendations.contains { $0.kind == .route && $0.target == "github.com" },
                      "the one-profile host is the other finding")
        XCTAssertFalse(recommendations.contains { $0.kind == .retire },
                       "nothing bound here is unused")
    }
}
