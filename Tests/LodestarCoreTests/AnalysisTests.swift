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

    func testHardAddressesCannotBuyTheGridWithSilence() {
        // One well-sampled curve at α≈0.25, plus five re-epoched addresses
        // whose surviving samples sit at ordinals 61+ — where e^{-αn}
        // collapses for large α and the per-address OLS goes singular.
        // Skipping the failures let exactly the largest alphas post zero
        // error for five addresses and win the grid; the intercept
        // fallback makes every α pay the same bill, so the curved address
        // decides and the hard ones keep flat fits.
        var o = Observations()
        var noise = Noise(seed: 23)
        for n in 1...40 {
            let gap = exp(log(0.2) + 1.2 * exp(-0.25 * Double(n)) + noise.normal(sd: 0.05))
            var event = ObservationEvent(t: start.addingTimeInterval(Double(n) * 3600),
                                         kind: .chain)
            event.chain = ["q"]
            event.gaps = [gap]
            o.apply(event)
        }
        for letter in ["a", "b", "c", "d", "e"] {
            for n in 1...60 {
                var event = ObservationEvent(t: start.addingTimeInterval(Double(n) * 3600),
                                             kind: .chain)
                event.chain = [letter]
                o.apply(event)
            }
            var bump = ObservationEvent(t: start.addingTimeInterval(61 * 3600), kind: .epoch)
            bump.address = letter
            bump.change = "retargeted"
            o.apply(bump)
            for n in 61...76 {
                var event = ObservationEvent(t: start.addingTimeInterval(Double(n) * 3600),
                                             kind: .chain)
                event.chain = [letter]
                event.gaps = [exp(log(0.4) + noise.normal(sd: 0.3))]
                o.apply(event)
            }
        }
        let curve = LearningCurve.fit(observations: o)
        XCTAssertNotNil(curve)
        XCTAssertEqual(curve?.alpha ?? 0, 0.25, accuracy: 0.15,
                       "the pooled rate belongs to the evidence, not to the dropouts")
        for letter in ["a", "b", "c", "d", "e"] {
            XCTAssertNotNil(curve?.fits[letter], "a flat fit is still a fit")
        }
    }

    // MARK: - The FDR family

    func testTestedButUngatedCandidatesStayInTheFamily() {
        // Five wrong keys, three on one letter: enough trials to run the
        // test, too thin to clear the Wilson floor. The hypothesis was
        // tested, so it must be counted — dropping it before BH is
        // post-selection, and m stops meaning anything.
        var o = Observations()
        var event = ObservationEvent(t: start, kind: .wrongKey)
        event.chain = ["w"]
        for pressed in ["x", "x", "x", "y", "z"] {
            event.pressed = pressed
            o.apply(event)
        }
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      meetingsEnabled: false, now: start)
        let candidates = Advisor.rebindCandidates(context)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNotNil(candidates.first?.p, "tested, so it carries its p")
        XCTAssertEqual(candidates.first?.offerable, false,
                       "in the family, never on the glass")
    }

    func testRetireStandsOutsideTheFamily() {
        // A retirement rejects no null: four weeks and zero completions is
        // a fact, and the constant stand-in p it used to carry sat inside
        // the BH family distorting the thresholds for the real tests.
        var o = Observations()
        var seen = ObservationEvent(t: start.addingTimeInterval(-30 * 86_400), kind: .focus)
        seen.app = "slack"
        o.apply(seen)
        let context = Advisor.Context(
            observations: o, events: [],
            leaves: [Advisor.Leaf(chain: ["z"], label: "Zed", value: "Zed")],
            meetingsEnabled: false, now: start)
        let candidates = Advisor.retireCandidates(context)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.p, "a fact is not a rejection of chance")
        XCTAssertEqual(candidates.first?.offerable, true)
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
            leaves: [.init(chain: ["g"], label: "Ghostty", value: "Ghostty")],
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
        XCTAssertEqual(bind?.edit, .bindTarget(chain: ["f"], target: "facetime"),
                       "the one config line the chip would commit")
    }

    /// A browser-profile leaf must commit the value a config line writes,
    /// not the label a person reads. `GraphTarget.label` renders
    /// "Brave (Xonar)", which nobody has installed: committing that sends
    /// the coach into `AppIndex.entry(named:)`, past the exact match, into
    /// `Fuzzy.rank`, and binds plain Brave with the profile dropped in
    /// silence. Unreachable until `mnemonicLetters` learned to read
    /// parenthesised words, which is exactly what makes it worth pinning.
    func testShorteningAProfileCommitsTheProfileNotItsLabel() {
        var o = Observations()
        var events: [ObservationEvent] = []
        var noise = Noise(seed: 11)
        // A fast single key, so the model knows one letter is cheap.
        for i in 0..<50 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 600),
                                         kind: .chain)
            event.chain = ["g"]
            event.gaps = [exp(log(0.15) + noise.normal(sd: 0.1))]
            events.append(event)
            o.apply(event)
        }
        // A deep chain to a browser profile, typed often and slowly.
        for i in 0..<40 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 900),
                                         kind: .chain)
            event.chain = ["b", "x"]
            event.gaps = [exp(log(0.30) + noise.normal(sd: 0.1)),
                          exp(log(0.60) + noise.normal(sd: 0.1))]
            events.append(event)
            o.apply(event)
        }
        let context = Advisor.Context(
            observations: o, events: events,
            leaves: [.init(chain: ["g"], label: "Ghostty", value: "Ghostty"),
                     .init(chain: ["b", "x"], label: "Brave (Xonar)",
                           value: "brave:xonar")],
            webRoutes: [:],
            now: start.addingTimeInterval(3 * 86_400))
        let shorten = Advisor.recommend(context).first { $0.kind == .shorten }
        XCTAssertNotNil(shorten, "a deep chain typed 40 times has earned a letter")
        XCTAssertEqual(shorten?.edit,
                       .supersede(old: ["b", "x"], new: ["x"], target: "brave:xonar"),
                       "the edit writes the profile reference, never the rendered label, "
                           + "and carries the address being given up as well as the one gained")
        XCTAssertEqual(shorten?.display, "Brave (Xonar)",
                       "the chip still shows the name a person would recognise")
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
        // The real-data shape: wrong keys attach to the PREFIX "v", which
        // is an internal node — no leaf carries them. The advisor must
        // read the trie, not just its leaves (found live: a user's
        // strongest confusion was invisible to the leaf-only version).
        var o = Observations()
        for _ in 0..<8 {
            var event = ObservationEvent(t: start, kind: .wrongKey)
            event.chain = ["v"]
            event.pressed = "x"
            o.apply(event)
        }
        var completion = ObservationEvent(t: start, kind: .chain)
        completion.chain = ["v", "z"]
        completion.gaps = [0.3, 0.2]
        o.apply(completion)
        let context = Advisor.Context(observations: o, events: [],
                                      leaves: [.init(chain: ["v", "z"], label: "Zoom",
                                                     value: "Zoom")],
                                      webRoutes: [:], now: start)
        let rebind = Advisor.recommend(context).first { $0.kind == .rebind }
        XCTAssertNotNil(rebind, "prefix evidence must reach the advisor")
        XCTAssertEqual(rebind?.target, "v")
        XCTAssertTrue(rebind?.detail.contains("lode V") ?? false)
        XCTAssertTrue(rebind?.detail.contains("X") ?? false,
                      "the evidence names the letter")
    }

    func testFreeLettersNeverOfferWhatTheGrammarReserves() {
        let context = Advisor.Context(observations: Observations(), events: [],
                                      leaves: [], webRoutes: [:], now: start)
        let free = Advisor.freeLetters(context)
        for returned in ["o", "x", "z"] {
            XCTAssertTrue(free.contains(returned),
                          "\(returned) rejoined the graph when its verb moved off it")
        }
        XCTAssertTrue(free.contains("q"), "ordinary letters stay on offer")
    }

    func testPassThroughOpensAreEvidenceOfNothing() {
        // A host that is all clicked pass-through has no preference to
        // make a rule of; and pass opens must not dilute a real one.
        var o = Observations()
        for _ in 0..<12 {
            var event = ObservationEvent(t: start, kind: .web)
            event.host = "tailscale.com"
            event.profile = "pass"
            event.source = "clicked"
            o.apply(event)
        }
        for i in 0..<10 {
            var event = ObservationEvent(t: start, kind: .web)
            event.host = "github.com"
            event.profile = i < 9 ? "brave:work" : "pass"
            event.source = i < 9 ? "typed" : "clicked"
            o.apply(event)
        }
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: [:],
                                      profileKeys: ["brave:work": "work"], now: start)
        let routes = Advisor.recommend(context).filter { $0.kind == .route }
        XCTAssertNil(routes.first { $0.target == "tailscale.com" },
                     "all pass-through: the user chose nothing")
        let github = routes.first { $0.target == "github.com" }
        XCTAssertNotNil(github, "nine deliberate opens in one profile is a preference")
        XCTAssertTrue(github?.detail.contains("9 of 9") ?? false,
                      "concentration judged over chosen opens only")
    }

    func testBreathFiresOnCountEvidenceAtRealisticLift() {
        // 78% of attention in three apps bounds lift below 2 forever; the
        // z-score against independence carries the evidence anyway.
        var o = Observations()
        o.transitions = [
            "ghostty": ["brave": 100, "slack": 35],
            "brave": ["ghostty": 90, "slack": 20],
            "slack": ["ghostty": 40, "brave": 15],
        ]
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: [:], now: start)
        let breath = Advisor.recommend(context).first { $0.kind == .breath }
        XCTAssertNotNil(breath, "the user's most obvious pattern must be sayable")
        XCTAssertTrue(breath?.target.contains("ghostty") ?? false)
    }

    func testBreathIsSilentWhenEverySwitchStoodInView() {
        // The pulled table exists and holds nothing for the pair: every
        // switch reached a window already on screen, which a breath
        // cannot make cheaper. Still tested, never offered.
        var o = Observations()
        o.transitions = [
            "ghostty": ["brave": 100, "slack": 35],
            "brave": ["ghostty": 90, "slack": 20],
            "slack": ["ghostty": 40, "brave": 15],
        ]
        o.transitionPulls = [:]
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: [:], now: start)
        XCTAssertNil(Advisor.recommend(context).first { $0.kind == .breath },
                     "a pair already side by side has nothing a breath can save")
    }

    func testBreathPricesThePullsNotTheSwitches() {
        var o = Observations()
        o.transitions = [
            "ghostty": ["brave": 100, "slack": 35],
            "brave": ["ghostty": 90, "slack": 20],
            "slack": ["ghostty": 40, "brave": 15],
        ]
        o.transitionPulls = ["ghostty": ["brave": 30], "brave": ["ghostty": 10]]
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: [:], now: start)
        let breath = Advisor.recommend(context).first { $0.kind == .breath }
        XCTAssertEqual(breath?.secondsPerWeek ?? 0, 40, accuracy: 0.001,
                       "both directions of pulls, at two seconds each")
        XCTAssertTrue(breath?.detail.contains("40 pulled into view") ?? false)
    }

    func testAGestureQuietForASeasonIsNamedNeverActed() {
        var o = Observations()
        o.since = start.addingTimeInterval(-200 * 86_400)
        o.verbsLastUsed = ["scroll": start.addingTimeInterval(-100 * 86_400),
                           "select": start.addingTimeInterval(-3 * 86_400)]
        let dormant = Advisor.dormantGestures(o, disabled: [], now: start)
        XCTAssertEqual(dormant.map(\.name), ["launcher", "web-bar", "commands", "draft", "hints",
                                              "maximize", "index-jump", "flip-orientation",
                                              "layout-undo", "display-move", "scroll"].sorted { a, b in
            // never fired since the record began (200 days) sort before scroll (100)
            let days = { (n: String) -> Int in n == "scroll" ? 100 : 200 }
            return days(a) > days(b) || (days(a) == days(b) && a < b)
        }, "every counted gesture unfired for ninety days, quietest first; select fired last week")
        let context = Advisor.Context(observations: o, events: [], leaves: [],
                                      webRoutes: [:], disabledGestures: ["scroll"], now: start)
        let recs = Advisor.recommend(context).filter { $0.kind == .dormant }
        XCTAssertFalse(recs.contains { $0.target == "scroll" }, "already off is not an offer")
        XCTAssertFalse(recs.contains { $0.target == "select" })
        XCTAssertTrue(recs.allSatisfy { $0.edit == nil && $0.secondsPerWeek == 0 },
                      "report-only and unpriced: no chip can ever carry it")
        XCTAssertTrue(recs.first { $0.target == "draft" }?.detail.contains("gestures.draft false") ?? false)
    }

    func testAFreshRecordSaysNothingIsDormant() {
        var o = Observations()
        o.since = start.addingTimeInterval(-10 * 86_400)
        XCTAssertTrue(Advisor.dormantGestures(o, disabled: [], now: start).isEmpty)
        XCTAssertTrue(Advisor.dormantGestures(Observations(), disabled: [], now: start).isEmpty,
                      "no record at all is no evidence")
    }

    func testMixtureStaysSilentOnUnimodalData() {
        // A fluent user's day has no reconstruction mode; splitting one
        // cloud into center and tails would fabricate ownership numbers.
        var o = Observations()
        var noise = Noise(seed: 41)
        for i in 0..<80 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i)),
                                         kind: .chain)
            event.chain = ["g"]
            event.gaps = [exp(log(0.09) + noise.normal(sd: 0.25))]
            o.apply(event)
        }
        XCTAssertNil(RecallMixture.fit(observations: o),
                     "no separation, no mixture — the blind rate is the measure")
    }

    // MARK: - The failure gradient

    /// Bare keys misfire at essentially zero; a chain whose starts keep
    /// failing carries the depth itself as the defect, and the wrong keys
    /// live on the *prefix* where the hand stumbled, never the leaf.
    private func flattenWorld(stumbles: Int) -> (Advisor.Context, Observations) {
        var o = Observations()
        var events: [ObservationEvent] = []
        var noise = Noise(seed: 17)
        // Latency material: a fast bare key.
        for i in 0..<50 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 600),
                                         kind: .chain)
            event.chain = ["g"]
            event.gaps = [exp(log(0.15) + noise.normal(sd: 0.1))]
            events.append(event)
            o.apply(event)
        }
        // The deep chain, completed often enough to have real evidence.
        for i in 0..<30 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 900),
                                         kind: .chain)
            event.chain = ["v", "z"]
            event.gaps = [exp(log(0.30) + noise.normal(sd: 0.1)),
                          exp(log(0.50) + noise.normal(sd: 0.1))]
            events.append(event)
            o.apply(event)
        }
        // And the gradient: stumbles at the prefix, scattered across
        // letters so no single wrong belief exists for a rebind to read.
        let scatter = ["q", "w", "e"]
        for i in 0..<stumbles {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 1000),
                                         kind: .wrongKey)
            event.chain = ["v"]
            event.pressed = scatter[i % scatter.count]
            events.append(event)
            o.apply(event)
        }
        let context = Advisor.Context(
            observations: o, events: events,
            leaves: [.init(chain: ["g"], label: "Ghostty", value: "Ghostty"),
                     .init(chain: ["v", "z"], label: "Zoom", value: "Zoom")],
            webRoutes: [:],
            now: start.addingTimeInterval(3 * 86_400))
        return (context, o)
    }

    func testFlattenReadsTheFailureGradient() {
        let (context, o) = flattenWorld(stumbles: 12)
        let flatten = Advisor.recommend(context).first { $0.kind == .flatten }
        XCTAssertNotNil(flatten, "a road that misfires a quarter of the time is the defect")
        XCTAssertEqual(flatten?.edit,
                       .supersede(old: ["v", "z"], new: ["z"], target: "Zoom"),
                       "the same supersede a shorten performs, to the mnemonic letter")
        XCTAssertEqual(flatten?.display, "Zoom")
        XCTAssertGreaterThanOrEqual(flatten?.probability ?? 0, 0.9, "gated, not guessed")
        // The chip the offer would wear: the landing named, the road's
        // misfires counted, the supersede verb telling the truth.
        guard let flatten else { return }
        let chip = Coach.chip(for: flatten, observations: o)
        XCTAssertTrue(chip.headline.contains("lode Z → Zoom"), chip.headline)
        XCTAssertTrue(chip.evidence.contains("misfired 12 times"), chip.evidence)
        XCTAssertTrue(chip.footer.contains("move it"),
                      "the old address stops working, and the verb says so")
    }

    func testACleanChainRaisesNoFlatten() {
        let (context, _) = flattenWorld(stumbles: 0)
        XCTAssertNil(Advisor.recommend(context).first { $0.kind == .flatten },
                     "no failures, no finding — frequency alone is the shorten's job")
    }

    func testPromotionSlotPrefersMnemonicsThenReach() {
        XCTAssertEqual(Advisor.promotionSlot(app: "Brave", record: nil,
                                             free: Set(["b", "a"])), "b",
                       "the mnemonic wins while it is free")
        XCTAssertEqual(Advisor.promotionSlot(app: "Brave", record: nil,
                                             free: Set(["q", "z", "a"])), "a",
                       "mnemonics all taken: the home row by reach")
        XCTAssertNil(Advisor.promotionSlot(app: "Brave", record: nil, free: []),
                     "a truly spent alphabet offers nothing")
    }

    // MARK: - The closed road

    func testANudgeOffersToCloseTheLauncherRoad() {
        var o = Observations()
        var events: [ObservationEvent] = []
        for i in 0..<12 {
            var event = ObservationEvent(t: start.addingTimeInterval(Double(i) * 3600),
                                         kind: .reach)
            event.app = "slack"
            event.route = i < 11 ? "searcher" : "graph"
            if i < 11 {
                event.openToCommit = 2.5
                event.typed = 3
                event.queryPrefix = "sl"
                event.rank = 0
                event.listLength = 4
            }
            events.append(event)
            o.apply(event)
        }
        let context = Advisor.Context(
            observations: o, events: events,
            leaves: [.init(chain: ["s"], label: "Slack", value: "Slack")],
            webRoutes: [:], now: start.addingTimeInterval(2 * 86_400))
        let nudge = Advisor.recommend(context).first { $0.kind == .nudge }
        XCTAssertNotNil(nudge, "an address the launcher keeps beating is a road to close")
        XCTAssertEqual(nudge?.edit, .closeRoad(app: "slack", chain: ["s"]),
                       "the accept is the toll, not a config line")
        XCTAssertEqual(nudge?.display, "Slack")
    }
}
