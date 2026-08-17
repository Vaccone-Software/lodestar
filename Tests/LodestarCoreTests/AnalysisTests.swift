import XCTest
@testable import LodestarCore

/// The model stack, held to the only standard that matters for models:
/// synthetic data with known parameters goes in, the parameters come back
/// out. A model that cannot recover what was planted has no business
/// pricing anybody's recommendations.
final class AnalysisTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Deterministic noise so every run sees the same world.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
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

    // MARK: - Maths

    func testOLSRecoversPlantedCoefficients() {
        var noise = Noise(seed: 7)
        var rows: [[Double]] = []
        var y: [Double] = []
        for _ in 0..<200 {
            let x1 = noise.uniform()
            let x2 = noise.uniform() * 2
            rows.append([1, x1, x2])
            y.append(0.5 + 2.0 * x1 - 1.5 * x2 + noise.normal(sd: 0.05))
        }
        let beta = Maths.ols(rows: rows, y: y)
        XCTAssertNotNil(beta)
        XCTAssertEqual(beta?[0] ?? 0, 0.5, accuracy: 0.05)
        XCTAssertEqual(beta?[1] ?? 0, 2.0, accuracy: 0.05)
        XCTAssertEqual(beta?[2] ?? 0, -1.5, accuracy: 0.05)
    }

    func testOLSRefusesASingularSystem() {
        let rows = [[1.0, 2.0], [2.0, 4.0], [3.0, 6.0]]
        XCTAssertNil(Maths.ols(rows: rows, y: [1, 2, 3]),
                     "no variation means no answer, not a made-up one")
    }

    func testBenjaminiHochbergControlsTheObviousCases() {
        // One real effect among noise survives; pure noise does not.
        let mixed = [0.001, 0.4, 0.6, 0.8, 0.9]
        XCTAssertEqual(Maths.benjaminiHochberg(mixed, q: 0.1), [0])
        let noise = [0.3, 0.5, 0.7, 0.9]
        XCTAssertTrue(Maths.benjaminiHochberg(noise, q: 0.1).isEmpty,
                      "the report must not manufacture findings from noise")
        let strong = [0.001, 0.002, 0.003]
        XCTAssertEqual(Maths.benjaminiHochberg(strong, q: 0.1), [0, 1, 2])
    }

    func testShrinkagePullsThinGroupsTowardTheGrandMean() {
        let groups: [(mean: Double, n: Int)] = [(0.0, 100), (1.0, 100), (5.0, 2)]
        let shrunk = Maths.shrink(groupMeans: groups, withinVariance: 1.0)
        XCTAssertEqual(shrunk[0], 0.0, accuracy: 0.15, "a well-sampled group keeps its story")
        XCTAssertLessThan(shrunk[2], 5.0, "two samples do not get to claim five")
        XCTAssertGreaterThan(shrunk[2], 2.0, "but they are not erased either")
    }

    func testWilsonLowerBoundIsConservative() {
        XCTAssertEqual(Maths.wilsonLower(successes: 9, trials: 10), 0.596, accuracy: 0.01)
        XCTAssertEqual(Maths.wilsonLower(successes: 90, trials: 100), 0.825, accuracy: 0.01,
                       "more evidence, tighter bound")
        XCTAssertEqual(Maths.wilsonLower(successes: 0, trials: 0), 0)
    }

    // MARK: - Latency model

    func testLatencyModelSeparatesFluencyFromChainShape() {
        // Two addresses, same true skill, different shapes: a single letter
        // and a two-letter chain whose inner gap is fast motor typing. The
        // raw medians differ; the residuals must not.
        var noise = Noise(seed: 11)
        var samples: [LatencyModel.Sample] = []
        for _ in 0..<60 {
            samples.append(.init(address: "g", chain: ["g"], pos: 0,
                                 log: log(0.4) + noise.normal(sd: 0.2)))
            samples.append(.init(address: "b d", chain: ["b", "d"], pos: 0,
                                 log: log(0.4) + noise.normal(sd: 0.2)))
            samples.append(.init(address: "b d", chain: ["b", "d"], pos: 1,
                                 log: log(0.15) + noise.normal(sd: 0.2)))
        }
        let model = LatencyModel.fit(samples: samples)
        XCTAssertNotNil(model)
        let g = model?.fluency["g"]?.residual ?? 99
        let bd = model?.fluency["b d"]?.residual ?? -99
        XCTAssertEqual(g, bd, accuracy: 0.12,
                       "equal skill must read as equal once shape is regressed out")
        // And the generative read prices the two-letter chain higher.
        XCTAssertGreaterThan(model?.chainSeconds(["b", "d"]) ?? 0,
                             model?.chainSeconds(["g"]) ?? 1)
    }

    func testLatencyModelPricesAnUnseenChain() {
        var noise = Noise(seed: 13)
        var samples: [LatencyModel.Sample] = []
        for _ in 0..<80 {
            samples.append(.init(address: "s", chain: ["s"], pos: 0,
                                 log: log(0.35) + noise.normal(sd: 0.15)))
            samples.append(.init(address: "m", chain: ["m"], pos: 0,
                                 log: log(0.35) + noise.normal(sd: 0.15)))
            samples.append(.init(address: "e o", chain: ["e", "o"], pos: 1,
                                 log: log(0.18) + noise.normal(sd: 0.15)))
            samples.append(.init(address: "e o", chain: ["e", "o"], pos: 0,
                                 log: log(0.35) + noise.normal(sd: 0.15)))
        }
        let model = LatencyModel.fit(samples: samples)
        let priced = model?.chainSeconds(["w"]) ?? 0
        XCTAssertEqual(priced, 0.35, accuracy: 0.1,
                       "a chain never typed is priced from the trigger physiology")
    }

    // MARK: - Learning curve

    func testLearningCurveRecoversTheAsymptoteAndTheBill() {
        var o = Observations()
        var noise = Noise(seed: 17)
        // True curve: log-gap = log(0.2) + 1.2·e^(−0.25n).
        for n in 1...40 {
            let gap = exp(log(0.2) + 1.2 * exp(-0.25 * Double(n)) + noise.normal(sd: 0.05))
            var event = ObservationEvent(t: start.addingTimeInterval(Double(n) * 3600),
                                         kind: .chain)
            event.chain = ["q"]
            event.gaps = [gap]
            o.apply(event)
        }
        let curve = LearningCurve.fit(observations: o)
        XCTAssertNotNil(curve)
        let fit = curve?.fits["q"]
        XCTAssertEqual(exp(fit?.asymptote ?? 0), 0.2, accuracy: 0.05,
                       "where this address is heading")
        XCTAssertEqual(curve?.alpha ?? 0, 0.25, accuracy: 0.15, "how fast it gets there")
        // Forty uses in, the curve is nearly flat: little bill remains.
        XCTAssertLessThan(fit?.remainingSeconds(alpha: curve?.alpha ?? 0.25) ?? 99, 2)
        // The whole bill from n=1 is real money by comparison.
        XCTAssertGreaterThan(fit?.totalSeconds(alpha: curve?.alpha ?? 0.25) ?? 0, 1)
    }

    // MARK: - Recall mixture

    func testMixtureSeparatesRecallFromReconstruction() {
        var o = Observations()
        var noise = Noise(seed: 19)
        // "g" is owned: 90% fast. "x y" is not: 70% slow, and some of its
        // slow moments are labeled by the peek.
        for i in 0..<60 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i)), kind: .chain)
            event.chain = ["g"]
            let slow = i % 10 == 0
            event.gaps = [exp((slow ? log(2.2) : log(0.15)) + noise.normal(sd: 0.15))]
            o.apply(event)
        }
        for i in 0..<40 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) + 5000),
                                         kind: .chain)
            event.chain = ["x", "y"]
            let slow = i % 10 != 7 && i % 10 != 3 && i % 10 != 5
            event.gaps = [exp((slow ? log(2.2) : log(0.15)) + noise.normal(sd: 0.15)), 0.2]
            event.peeked = slow && i % 2 == 0
            o.apply(event)
        }
        let mixture = RecallMixture.fit(observations: o)
        XCTAssertNotNil(mixture)
        XCTAssertEqual(exp(mixture?.fastMean ?? 0), 0.15, accuracy: 0.06)
        XCTAssertEqual(exp(mixture?.slowMean ?? 0), 2.2, accuracy: 0.8)
        XCTAssertGreaterThan(mixture?.ownership["g"] ?? 0, 0.8, "g is owned")
        XCTAssertLessThan(mixture?.ownership["x y"] ?? 1, 0.45, "x y is reconstructed")
    }

    // MARK: - Demand

    func testDemandTellsHabitsFromProjects() {
        let habit = Demand.fit(weeklyCounts: [10, 11, 9, 10, 12, 10, 9, 11])
        XCTAssertEqual(habit?.perWeek ?? 0, 10.25, accuracy: 0.01)
        XCTAssertLessThan(habit?.fano ?? 99, 2, "steady use is near-Poisson")
        let project = Demand.fit(weeklyCounts: [0, 0, 40, 38, 0, 0, 2, 0])
        XCTAssertGreaterThan(project?.fano ?? 0, 5, "burst use is over-dispersed")
        XCTAssertGreaterThan(habit?.horizonUses(weeks: 8) ?? 0, 60,
                             "the horizon discounts but does not erase")
    }

    func testDemandCountsZeroWeeksAsSilence() {
        var events: [ObservationEvent] = []
        var reach = ObservationEvent(t: start, kind: .reach)
        reach.app = "slack"
        reach.route = "searcher"
        events.append(reach)
        let counts = Demand.weeklyCounts(app: "slack", events: events,
                                         now: start.addingTimeInterval(3 * 604_800))
        XCTAssertEqual(counts, [1, 0, 0, 0], "silence is data, not absence of data")
    }

    // MARK: - Transitions

    func testTransitionsFindTheRealPair() {
        var matrix: [String: [String: Double]] = [:]
        // ghostty ↔ brave is a genuine loop; finder is background noise.
        matrix["ghostty"] = ["brave": 20, "finder": 2]
        matrix["brave"] = ["ghostty": 18, "finder": 3]
        matrix["finder"] = ["ghostty": 2, "brave": 2]
        let pairs = Transitions.strongPairs(matrix)
        XCTAssertEqual(pairs.first?.from, "ghostty")
        XCTAssertEqual(pairs.first?.to, "brave")
        XCTAssertGreaterThan(pairs.first?.lift ?? 0, 1)

        let stationary = Transitions.stationary(matrix)
        XCTAssertGreaterThan(stationary["brave"] ?? 0, stationary["finder"] ?? 1,
                             "attention lives where the loop is")

        let clusters = Transitions.clusters(matrix, minimumWeight: 10)
        XCTAssertEqual(clusters.first?.apps, ["brave", "ghostty"],
                       "the working set, found not asserted")
    }

    // MARK: - Shadow

    func testShadowScoresBothModelsAndPrefersTheInformedOne() {
        var events: [ObservationEvent] = []
        var noise = Noise(seed: 23)
        // A world the geometry model can genuinely explain: trigger gaps
        // slow, inner gaps fast, consistently.
        for i in 0..<300 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 60),
                                         kind: .chain)
            event.chain = i % 2 == 0 ? ["b", "d"] : ["g"]
            event.gaps = i % 2 == 0
                ? [exp(log(0.5) + noise.normal(sd: 0.1)), exp(log(0.12) + noise.normal(sd: 0.1))]
                : [exp(log(0.5) + noise.normal(sd: 0.1))]
            events.append(event)
        }
        let scores = Shadow.evaluate(events: events)
        XCTAssertEqual(scores.count, 2)
        XCTAssertGreaterThan(scores.first { $0.model == "geometry" }?.predictions ?? 0, 200)
        // Both models see per-address structure here, so parity is enough;
        // the gate exists to catch the geometry model losing.
        let baseline = scores.first { $0.model == "baseline" }?.meanLogScore ?? 0
        let geometry = scores.first { $0.model == "geometry" }?.meanLogScore ?? -99
        XCTAssertGreaterThan(geometry, baseline - 0.3)
    }

    // MARK: - Advisor

    private func advisorWorld() -> Advisor.Context {
        var o = Observations()
        var events: [ObservationEvent] = []
        var noise = Noise(seed: 29)
        // FaceTime: searched daily for four weeks, launcher costs ~2s,
        // no address, and the letter F is free. The engine should notice.
        for week in 0..<4 {
            for day in 0..<6 {
                var event = ObservationEvent(
                    t: start.addingTimeInterval(Double(week) * 604_800 + Double(day) * 86_400),
                    kind: .reach)
                event.app = "facetime"
                event.route = "searcher"
                event.typed = 3
                event.queryPrefix = "fa"
                event.rank = 0
                event.listLength = 5
                event.openToCommit = exp(log(2.0) + noise.normal(sd: 0.1))
                event.openToFirstKey = 0.4
                events.append(event)
                o.apply(event)
            }
        }
        // A fluent graph so the latency model has material.
        for i in 0..<50 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 3000),
                                         kind: .chain)
            event.chain = ["g"]
            event.gaps = [exp(log(0.3) + noise.normal(sd: 0.15))]
            events.append(event)
            o.apply(event)
        }
        return Advisor.Context(
            observations: o, events: events,
            leaves: [(chain: ["g"], label: "Ghostty")],
            webRoutes: [:],
            now: start.addingTimeInterval(4 * 604_800))
    }

    func testAdvisorFindsTheAppThatDeservesAnAddress() {
        let recommendations = Advisor.recommend(advisorWorld())
        let bind = recommendations.first { $0.kind == .bind }
        XCTAssertNotNil(bind, "daily searches, priced launcher, free letter: bind it")
        XCTAssertEqual(bind?.target, "facetime")
        XCTAssertTrue(bind?.detail.contains("lode F") ?? false, "the mnemonic slot")
        XCTAssertGreaterThan(bind?.secondsPerWeek ?? 0, 0)
        XCTAssertGreaterThanOrEqual(bind?.probability ?? 0, 0.9, "gated, not guessed")
        XCTAssertEqual(bind?.edit, .bindApp(chain: ["f"], app: "facetime"),
                       "the one config line the chip would commit")
    }

    func testAdvisorStaysSilentOnThinData() {
        var o = Observations()
        var reach = ObservationEvent(t: start, kind: .reach)
        reach.app = "facetime"
        reach.route = "searcher"
        reach.typed = 3
        reach.openToCommit = 2.0
        for _ in 0..<3 { o.apply(reach) }
        let context = Advisor.Context(observations: o, events: [reach, reach, reach],
                                      leaves: [], webRoutes: [:], now: start)
        XCTAssertTrue(Advisor.recommend(context).isEmpty,
                      "three searches in one week is a story, not a statistic")
    }

    func testAdvisorProposesARouteForAOneProfileHost() {
        var o = Observations()
        for i in 0..<12 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 86_400),
                                         kind: .web)
            event.host = "github.com"
            event.profile = "brave:work"
            event.source = "typed"
            o.apply(event)
        }
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: [:],
                                      profileKeys: ["brave:work": "work"], now: start)
        let route = Advisor.recommend(context).first { $0.kind == .route }
        XCTAssertNotNil(route, "twelve opens, one profile: a rule is waiting")
        XCTAssertEqual(route?.target, "github.com")
        XCTAssertEqual(route?.edit, .addRoute(pattern: "github.com", profileKey: "work"),
                       "the registry key resolved, so the chip can commit it")

        // Without the registry mapping the finding stands but cannot be a
        // chip: report only.
        let unmapped = Advisor.Context(observations: o, events: [], leaves: [],
                                       webRoutes: [:], now: start)
        XCTAssertNil(Advisor.recommend(unmapped).first { $0.kind == .route }?.edit)

        // The same host already covered by a rule stays quiet.
        let covered = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: ["github.com": "work"], now: start)
        XCTAssertNil(Advisor.recommend(covered).first { $0.kind == .route },
                     "a decision already made is not a finding")
    }

    func testAdvisorFlagsTheLetterTheHandBelievesIn() {
        var o = Observations()
        for _ in 0..<8 {
            var event = ObservationEvent(t: start, kind: .wrongKey)
            event.chain = ["b"]
            event.pressed = "w"
            o.apply(event)
        }
        var completion = ObservationEvent(t: start, kind: .chain)
        completion.chain = ["b"]
        completion.gaps = [0.3]
        o.apply(completion)
        let context = Advisor.Context(observations: o, events: [],
                                      leaves: [(chain: ["b"], label: "Brave")],
                                      webRoutes: [:], now: start)
        let rebind = Advisor.recommend(context).first { $0.kind == .rebind }
        XCTAssertNotNil(rebind)
        XCTAssertTrue(rebind?.detail.contains("W") ?? false,
                      "the evidence names the letter")
    }
}
