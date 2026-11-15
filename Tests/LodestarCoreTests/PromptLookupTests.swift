import XCTest
@testable import LodestarCore

/// The guess the editor's model is checked against: its own input, found
/// again after every place the answer leaves it.
final class PromptLookupTests: XCTestCase {
    // "i think their going to be late" as tokens, one a word.
    let source = [1, 2, 3, 4, 5, 6, 7]

    func testTheFirstGuessIsTheInputsBeginning() {
        XCTAssertEqual(PromptLookup.draft(after: [], in: source, limit: 4), [1, 2, 3, 4])
        XCTAssertEqual(PromptLookup.draft(after: [], in: source, limit: 24), source)
    }

    func testTheGuessFollowsTheLastTokensWritten() {
        XCTAssertEqual(PromptLookup.draft(after: [1, 2], in: source, limit: 24), [3, 4, 5, 6, 7])
    }

    /// The model wrote "I" (90) for "i" and goes on copying: the run after
    /// the fix is found again from the tokens that agree.
    func testTheGuessIsFoundAgainAfterAFix() {
        XCTAssertEqual(PromptLookup.draft(after: [90, 2], in: source, limit: 24), [3, 4, 5, 6, 7])
        // "their" (4) became "they're" (91 92): "going" (5) realigns it.
        XCTAssertEqual(PromptLookup.draft(after: [90, 2, 3, 91, 92, 5], in: source, limit: 24), [6, 7])
    }

    func testNothingToGuessWhereTheInputHoldsNoneOfIt() {
        XCTAssertEqual(PromptLookup.draft(after: [80, 81], in: source, limit: 24), [])
        XCTAssertEqual(PromptLookup.draft(after: [7], in: source, limit: 24), [], "the input's end: nothing follows")
        XCTAssertEqual(PromptLookup.draft(after: [1], in: source, limit: 0), [])
    }

    /// "the" (9) twice: the place nearest to how far the answer has come.
    func testARepeatedTokenIsMatchedNearWhereTheAnswerIs() {
        let repeated = [9, 1, 2, 9, 3, 4]
        XCTAssertEqual(PromptLookup.draft(after: [9], in: repeated, limit: 2), [1, 2])
        XCTAssertEqual(PromptLookup.draft(after: [9, 1, 2, 70], in: repeated, limit: 2), [],
                       "70 is nowhere in the input")
        XCTAssertEqual(PromptLookup.draft(after: [9, 1, 2, 9], in: repeated, limit: 2), [3, 4],
                       "the longer run 2 9 decides")
        XCTAssertEqual(PromptLookup.draft(after: [9, 1, 70, 9], in: repeated, limit: 2), [3, 4],
                       "the later 9 is nearer the fourth token written")
    }

    func testTheGuessStandsWhileTheModelAgrees() {
        XCTAssertEqual(PromptLookup.accepted([3, 4, 5], predicted: [3, 4, 5, 99]), 3)
        XCTAssertEqual(PromptLookup.accepted([3, 4, 5], predicted: [3, 8, 5, 99]), 1)
        XCTAssertEqual(PromptLookup.accepted([3, 4, 5], predicted: [8, 4, 5, 99]), 0)
        XCTAssertEqual(PromptLookup.accepted([], predicted: [8]), 0)
    }

    /// Greedy decoding with and without the guess, on a stand-in model
    /// whose choice depends on everything written so far: the answers are
    /// the same tokens, and the guess saves steps.
    func testGuessingNeverChangesTheAnswer() {
        let input = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let stop = 0
        // The "model": copies the input, but answers 50 for 4 and adds 60
        // before stopping; its choice is a function of the whole prefix.
        func choose(after written: [Int]) -> Int {
            let corrected = input.map { $0 == 4 ? 50 : $0 } + [60]
            return written.count < corrected.count ? corrected[written.count] : stop
        }
        var plain: [Int] = []
        var plainSteps = 0
        while true {
            let next = choose(after: plain)
            plainSteps += 1
            if next == stop { break }
            plain.append(next)
        }
        var guessed: [Int] = []
        var guessSteps = 1
        var next = choose(after: [])
        while next != stop {
            guessed.append(next)
            let guess = PromptLookup.draft(after: guessed, in: input, limit: 24)
            var predicted: [Int] = []
            for k in 0...guess.count { predicted.append(choose(after: guessed + guess.prefix(k))) }
            guessSteps += 1
            let kept = PromptLookup.accepted(guess, predicted: predicted)
            guessed += guess[..<kept]
            next = predicted[kept]
        }
        XCTAssertEqual(guessed, plain)
        XCTAssertLessThan(guessSteps, plainSteps / 2, "the copying is read a run at a time")
    }
}
