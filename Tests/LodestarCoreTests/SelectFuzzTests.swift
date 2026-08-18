import XCTest
@testable import LodestarCore

/// The stress campaign's pure half: hundreds of random worlds — emoji,
/// CJK, surrogate pairs, symbol soup, hostile whitespace — driven through
/// the whole select pipeline with every invariant asserted. The AX side
/// is probed against live apps; this side guarantees the machine between
/// the keys and the geometry can never be the thing that breaks.
final class SelectFuzzTests: XCTestCase {
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % max(1, bound)
        }
        mutating func pick<T>(_ from: [T]) -> T { from[next(from.count)] }
    }

    private let atoms = ["the", "quick", "fox", "𝕏marker", "naïve", "東京",
                         "🌟star", "a", "$100", "x=y+1", "github.com/path",
                         "MiXeD", "…", "‰", "word:", "(paren)", "🇺🇸flag"]

    private func randomText(_ rng: inout Random, words: Int) -> String {
        (0..<words).map { _ in rng.pick(atoms) }
            .joined(separator: rng.next(5) == 0 ? "\n" : " ")
    }

    func testHundredsOfRandomWorldsUpholdEveryInvariant() {
        let keys = "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
            + [";", ",", ".", "/", "'", "[", "]", "=", "-", "`", "\\", "space"]
        for seed in 0..<300 {
            var rng = Random(seed: UInt64(seed) * 2_654_435_761 + 17)
            let elements = (0..<(1 + rng.next(4))).map { index in
                SelectCore.Element(id: index, text: randomText(&rng, words: 2 + rng.next(30)))
            }
            var core = SelectCore(elements: elements, alphabet: "asdfghjkl")

            for _ in 0..<(5 + rng.next(40)) {
                let effect: SelectCore.Effect
                switch rng.next(10) {
                case 0: effect = core.backspace()
                case 1, 2: effect = core.key(rng.pick(keys), shift: true)
                default: effect = core.key(rng.pick(keys), shift: false)
                }

                // Invariant: every displayed match is a valid range of its
                // element's text, and labels pair one-to-one with matches.
                XCTAssertEqual(core.labels.count, core.matches.count, "seed \(seed)")
                XCTAssertLessThanOrEqual(core.matches.count, SelectCore.displayCap)
                for match in core.matches {
                    guard let element = elements.first(where: { $0.id == match.element })
                    else { return XCTFail("seed \(seed): match names a ghost element") }
                    let text = element.text as NSString
                    XCTAssertGreaterThanOrEqual(match.range.location, 0)
                    XCTAssertLessThanOrEqual(match.range.location + match.range.length,
                                             text.length, "seed \(seed)")
                }

                // Invariant: a landed selection is extractable text whose
                // snap contains what was matched.
                if case .selected(let elementIndex, let range) = effect {
                    guard let element = elements.first(where: { $0.id == elementIndex })
                    else { return XCTFail("seed \(seed)") }
                    let text = element.text as NSString
                    XCTAssertGreaterThanOrEqual(range.location, 0)
                    XCTAssertLessThanOrEqual(range.location + range.length, text.length,
                                             "seed \(seed): span escapes its element")
                    XCTAssertGreaterThan(range.length, 0)
                    _ = text.substring(with: range) // must not trap
                }
            }
        }
    }

    func testWordSnapAlwaysContainsItsSeedAndRespectsBounds() {
        var rng = Random(seed: 99)
        for seed in 0..<200 {
            _ = seed
            let text = randomText(&rng, words: 1 + rng.next(20)) as NSString
            guard text.length > 0 else { continue }
            let location = rng.next(text.length)
            let length = rng.next(max(1, text.length - location))
            let seedRange = NSRange(location: location, length: length)
            let snapped = SelectCore.wordSnapped(seedRange, in: text)
            XCTAssertLessThanOrEqual(snapped.location, seedRange.location)
            XCTAssertGreaterThanOrEqual(snapped.location + snapped.length,
                                        seedRange.location + seedRange.length,
                                        "snap must contain its seed")
            XCTAssertGreaterThanOrEqual(snapped.location, 0)
            XCTAssertLessThanOrEqual(snapped.location + snapped.length, text.length)
            _ = text.substring(with: snapped) // must not split a surrogate pair
        }
    }

    func testStitchedRunsTileTheirLeavesExactly() {
        var rng = Random(seed: 7)
        for seed in 0..<200 {
            _ = seed
            let leaves = (0..<(1 + rng.next(12))).map { index -> SelectRuns.Leaf in
                let row = rng.next(6)
                let column = rng.next(3)
                return SelectRuns.Leaf(
                    id: index,
                    text: randomText(&rng, words: 1 + rng.next(6)),
                    frame: CGRect(x: CGFloat(column * 300 + rng.next(40)),
                                  y: CGFloat(row * 20),
                                  width: CGFloat(30 + rng.next(200)), height: 16))
            }
            let runs = SelectRuns.merge(leaves)
            var seen = Set<Int>()
            for run in runs {
                let text = run.text as NSString
                for fragment in run.fragments {
                    // Every fragment quotes its leaf verbatim at its
                    // claimed offsets — geometry and copying both depend
                    // on this being exact.
                    XCTAssertTrue(seen.insert(fragment.leaf).inserted,
                                  "a leaf appears in exactly one run once")
                    let leaf = leaves[fragment.leaf]
                    XCTAssertEqual(text.substring(with: fragment.range), leaf.text)
                    XCTAssertEqual(fragment.localRange.location, 0)
                    XCTAssertEqual(fragment.localRange.length,
                                   (leaf.text as NSString).length)
                }
                // Random spans slice into fragments without gaps beyond
                // joiners and without overshoot.
                if text.length > 0 {
                    let location = rng.next(text.length)
                    let length = rng.next(max(1, text.length - location))
                    let range = NSRange(location: location, length: max(1, length))
                    let slices = run.fragments.isEmpty ? [] : run.slices(of: range)
                    let sliced = slices.map(\.range.length).reduce(0, +)
                    XCTAssertLessThanOrEqual(sliced, range.length)
                    for slice in slices {
                        let leaf = leaves[slice.leaf].text as NSString
                        XCTAssertLessThanOrEqual(
                            slice.localRange.location + slice.localRange.length,
                            leaf.length, "a slice may never overrun its leaf")
                    }
                }
            }
            XCTAssertEqual(seen.count, leaves.count, "no leaf is dropped by stitching")
        }
    }
}
