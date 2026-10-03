import Foundation

// Audio longer than the encoder's 15 s window, heard in overlapping windows
// and joined at the seams without losing or doubling a word.
//
// Derived from FluidAudio (https://github.com/FluidInference/FluidAudio,
// commit 0b1f462), Copyright FluidInference, licensed under the Apache License,
// Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0):
// `ChunkProcessor.swift` (the v2 layout, mergeChunks, collapseSeamWordDuplicates,
// the seam-gap repair pass) and `SequenceMatcher.swift`. Changed for Lodestar:
// only the path FluidAudio takes for Parakeet v2 (80 ms of left context per
// window, regular strides, no end alignment), pure functions over
// `ParakeetToken`, no worker actors. The rules and constants are FluidAudio's,
// so a long hold is joined the way the measured probe joined it.

enum ParakeetSeams {
    /// The encoder's fixed input: 15 s at 16 kHz (mel 128 × 1501).
    static let windowSamples = 240_000
    /// Left context prepended to every window after the first, so the
    /// encoder's convolutions see the audio before the window (one frame).
    static let contextSamples = ParakeetTiming.samplesPerFrame
    /// Audio per window: the window less the context and one mel hop, on a
    /// frame boundary (14.88 s).
    static let chunkSamples = (windowSamples - contextSamples - 160) / ParakeetTiming.samplesPerFrame
        * ParakeetTiming.samplesPerFrame
    /// Windows overlap by 2 s.
    static let overlapSeconds = 2.0
    static let overlapSamples = min(Int(overlapSeconds * Double(ParakeetTiming.sampleRate)), chunkSamples / 2)
        / ParakeetTiming.samplesPerFrame * ParakeetTiming.samplesPerFrame
    static let strideSamples = (chunkSamples - overlapSamples) / ParakeetTiming.samplesPerFrame
        * ParakeetTiming.samplesPerFrame

    /// One window of a long recording.
    struct Window: Equatable {
        /// Where its audio starts, context included.
        var contextStart: Int
        /// Where its own audio starts; frames are counted from here.
        var start: Int
        var end: Int
        var isLast: Bool
        var context: Int { start - contextStart }
    }

    /// The windows that cover `total` samples (more than one window's worth).
    static func windows(total: Int) -> [Window] {
        var windows: [Window] = []
        var start = 0
        while start < total {
            let candidateEnd = start + chunkSamples
            let isLast = candidateEnd >= total
            let end = isLast ? total : candidateEnd
            if end <= start { break }
            let context = windows.isEmpty ? 0 : contextSamples
            windows.append(Window(contextStart: start - context, start: start, end: end, isLast: isLast))
            if isLast { break }
            start += strideSamples
        }
        return windows
    }

    // MARK: - Joining two windows

    /// Pieces that may begin a splice without gluing two words: word-initial
    /// or pure punctuation.
    static func spliceSafeIds(_ vocabulary: ParakeetVocabulary) -> Set<Int> {
        Set(vocabulary.pieces.compactMap { id, piece in
            (ParakeetVocabulary.startsWord(piece) || ParakeetVocabulary.isPunctuation(piece)) ? id : nil
        })
    }

    /// Ids with a case-only twin ("▁Meeting", "▁meeting") mapped to one
    /// canonical id (the lower-case one), so a seam word falsely capitalized
    /// by one window still anchors the join.
    static func caseVariants(_ vocabulary: ParakeetVocabulary) -> [Int: Int] {
        var groups: [String: [Int]] = [:]
        for (id, piece) in vocabulary.pieces { groups[piece.lowercased(), default: []].append(id) }
        var canonical: [Int: Int] = [:]
        for (folded, ids) in groups where ids.count > 1 {
            let keep = ids.first { vocabulary[$0] == folded } ?? ids.min()!
            for id in ids { canonical[id] = keep }
        }
        return canonical
    }

    private struct Indexed {
        let index: Int
        let token: ParakeetToken
        let start: Double
    }

    /// The left window's tokens joined to the right's, which overlaps it:
    /// the tokens both heard in the overlap are matched (same id, or case
    /// twins, within a second), and each side keeps what it heard best.
    static func merge(_ left: [ParakeetToken], _ right: [ParakeetToken],
                      spliceSafe: Set<Int>, caseVariants: [Int: Int]) -> [ParakeetToken] {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        let frame = ParakeetTiming.secondsPerFrame
        func start(_ t: ParakeetToken) -> Double { Double(t.frame) * frame }
        let leftEnd = start(left.last!) + frame
        let rightStart = start(right.first!)
        if leftEnd <= rightStart { return left + right }

        let overlapLeft: [Indexed] = left.enumerated().compactMap { i, t in
            start(t) + frame > rightStart - overlapSeconds ? Indexed(index: i, token: t, start: start(t)) : nil
        }
        let overlapRight: [Indexed] = right.enumerated().compactMap { i, t in
            start(t) < leftEnd + overlapSeconds ? Indexed(index: i, token: t, start: start(t)) : nil
        }
        guard overlapLeft.count >= 2, overlapRight.count >= 2 else {
            return mergeByMidpoint(left, right, leftEnd: leftEnd, rightStart: rightStart, spliceSafe: spliceSafe)
        }
        let tolerance = overlapSeconds / 2
        let matches: (Indexed, Indexed) -> Bool = { l, r in
            let sameId = l.token.id == r.token.id
                || (caseVariants[l.token.id] != nil && caseVariants[l.token.id] == caseVariants[r.token.id])
            return sameId && abs(l.start - r.start) < tolerance
        }
        let minimumPairs = max(overlapLeft.count / 2, 1)
        let contiguous = contiguousMatches(overlapLeft, overlapRight, matches)
        if contiguous.count >= minimumPairs {
            return mergeUsing(contiguous, overlapLeft, overlapRight, left, right, spliceSafe: spliceSafe)
        }
        let common = longestCommonSubsequence(overlapLeft, overlapRight, matches)
        guard !common.isEmpty else {
            return mergeByMidpoint(left, right, leftEnd: leftEnd, rightStart: rightStart, spliceSafe: spliceSafe)
        }
        return mergeUsing(common, overlapLeft, overlapRight, left, right, spliceSafe: spliceSafe)
    }

    /// The longest run of consecutive matches, as index pairs.
    static func contiguousMatches<T>(_ left: [T], _ right: [T], _ matches: (T, T) -> Bool) -> [(Int, Int)] {
        var best: [(Int, Int)] = []
        for i in 0..<left.count {
            for j in 0..<right.count where matches(left[i], right[j]) {
                var run: [(Int, Int)] = []
                var k = i, l = j
                while k < left.count, l < right.count, matches(left[k], right[l]) {
                    run.append((k, l))
                    k += 1
                    l += 1
                }
                if run.count > best.count { best = run }
            }
        }
        return best
    }

    /// The longest common subsequence, as index pairs in order.
    static func longestCommonSubsequence<T>(_ left: [T], _ right: [T], _ matches: (T, T) -> Bool) -> [(Int, Int)] {
        let n = left.count, m = right.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = matches(left[i - 1], right[j - 1]) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            if matches(left[i - 1], right[j - 1]) {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    private static func mergeUsing(_ pairs: [(Int, Int)], _ overlapLeft: [Indexed], _ overlapRight: [Indexed],
                                   _ left: [ParakeetToken], _ right: [ParakeetToken],
                                   spliceSafe: Set<Int>) -> [ParakeetToken] {
        let leftIndices = pairs.map { overlapLeft[$0.0].index }
        let rightIndices = pairs.map { overlapRight[$0.1].index }
        var result: [ParakeetToken] = []
        if let first = leftIndices.first, first > 0 { result.append(contentsOf: left[..<first]) }
        for k in 0..<pairs.count {
            let l = leftIndices[k], r = rightIndices[k]
            result.append(left[l])
            guard k < pairs.count - 1 else { continue }
            let nextL = leftIndices[k + 1], nextR = rightIndices[k + 1]
            let gapLeft = nextL > l + 1 ? Array(left[(l + 1)..<nextL]) : []
            let gapRight = nextR > r + 1 ? Array(right[(r + 1)..<nextR]) : []
            result.append(contentsOf: gapRight.count > gapLeft.count ? gapRight : gapLeft)
        }
        if let lastRight = rightIndices.last, lastRight + 1 < right.count {
            let tail = right[(lastRight + 1)...]
            if let first = tail.first, !spliceSafe.contains(first.id) {
                // The splice lands mid-word: let exactly one window own the
                // seam word.
                if let wordStart = (0...lastRight).reversed().first(where: { spliceSafe.contains(right[$0].id) }),
                   let cut = result.lastIndex(where: { spliceSafe.contains($0.id) }) {
                    // The right window heard the seam word from its start.
                    result.removeLast(result.count - cut)
                    result.append(contentsOf: right[wordStart...])
                } else {
                    // The right window begins mid-word: the left finishes the
                    // word and the right resumes at its next word.
                    if let lastLeft = leftIndices.last {
                        var cursor = lastLeft + 1
                        while cursor < left.count, !spliceSafe.contains(left[cursor].id) {
                            result.append(left[cursor])
                            cursor += 1
                        }
                    }
                    if let resume = tail.firstIndex(where: { spliceSafe.contains($0.id) }) {
                        result.append(contentsOf: tail[resume...])
                    } else {
                        result.append(contentsOf: tail)
                    }
                }
            } else {
                result.append(contentsOf: tail)
            }
        }
        return result
    }

    private static func mergeByMidpoint(_ left: [ParakeetToken], _ right: [ParakeetToken], leftEnd: Double,
                                        rightStart: Double, spliceSafe: Set<Int>) -> [ParakeetToken] {
        let cutoff = (leftEnd + rightStart) / 2
        let frame = ParakeetTiming.secondsPerFrame
        var leftCut = left.firstIndex { Double($0.frame) * frame >= cutoff } ?? left.count
        var rightCut = right.firstIndex { Double($0.frame) * frame >= cutoff } ?? right.count
        if leftCut > 0 {
            while leftCut < left.count, !spliceSafe.contains(left[leftCut].id) { leftCut += 1 }
        }
        var scan = rightCut
        while scan < right.count, !spliceSafe.contains(right[scan].id) { scan += 1 }
        if scan < right.count { rightCut = scan }
        return Array(left[..<leftCut]) + Array(right[rightCut...])
    }

    // MARK: - After the join

    /// Frames made non-decreasing without reordering: the merged order is
    /// the text's order; a token that would step back in time is clamped.
    static func monotonic(_ tokens: [ParakeetToken]) -> [ParakeetToken] {
        guard tokens.count > 1 else { return tokens }
        var result = tokens
        var last = result[0].frame
        for i in 1..<result.count {
            if result[i].frame < last { result[i].frame = last } else { last = result[i].frame }
        }
        return result
    }

    /// An adjacent case-only duplicate of a seam word ("have Have") left by
    /// one window's false sentence start goes; the lower-case copy stays.
    static func collapseCaseDuplicates(_ tokens: [ParakeetToken], vocabulary: ParakeetVocabulary) -> [ParakeetToken] {
        guard tokens.count > 1 else { return tokens }
        let overlapFrames = Int((overlapSeconds / ParakeetTiming.secondsPerFrame).rounded())
        struct Word { var tokens: [ParakeetToken]; var core = ""; var start: Int; var endsSentence = false }
        var words: [Word] = []
        for token in tokens {
            if words.isEmpty || ParakeetVocabulary.startsWord(vocabulary[token.id] ?? "") {
                words.append(Word(tokens: [token], start: token.frame))
            } else {
                words[words.count - 1].tokens.append(token)
            }
        }
        let strippable = CharacterSet.punctuationCharacters.union(.whitespaces)
        for i in words.indices {
            var text = ""
            for token in words[i].tokens {
                var piece = vocabulary[token.id] ?? ""
                if ParakeetVocabulary.startsWord(piece) { piece.removeFirst() }
                text += piece
            }
            words[i].core = text.trimmingCharacters(in: strippable)
            if let last = text.last { words[i].endsSentence = ".?!:".contains(last) }
        }
        var keep = [Bool](repeating: true, count: words.count)
        var lastKept = -1
        for i in words.indices {
            guard lastKept >= 0 else { lastKept = i; continue }
            let previous = words[lastKept], current = words[i]
            let duplicate = !previous.core.isEmpty && !current.core.isEmpty
                && previous.core != current.core
                && previous.core.lowercased() == current.core.lowercased()
                && current.core.first?.isLetter == true
                && !previous.endsSentence
                && current.start - previous.start <= overlapFrames
            guard duplicate else { lastKept = i; continue }
            if current.core == current.core.lowercased(), previous.core != previous.core.lowercased() {
                keep[lastKept] = false
                lastKept = i
            } else {
                keep[i] = false
            }
        }
        return words.indices.filter { keep[$0] }.flatMap { words[$0].tokens }
    }

    // MARK: - Seam-gap repair

    /// A gap between tokens this long (or longer) with speech in it is
    /// heard again by a fresh window.
    static let repairMinGapSeconds = 1.5
    /// Speech needed inside a gap before it is probed.
    static let repairMinSpeechSeconds = 0.5
    static let repairMaxProbes = 32
    /// The repair window: the whole encoder window less one mel hop.
    static let repairWindowSamples = max(ParakeetTiming.samplesPerFrame,
                                         (windowSamples - 160) / ParakeetTiming.samplesPerFrame
                                             * ParakeetTiming.samplesPerFrame)

    static let speechRmsCeiling: Float = 0.008
    static let speechRmsFloor: Float = 0.0005

    /// The recording's own speech level: a quarter of the way down its
    /// loudest frames, less 10.5 dB, held between the floor and the ceiling.
    static func speechThreshold(_ samples: [Float]) -> Float {
        let n = ParakeetTiming.samplesPerFrame
        var levels: [Float] = []
        var offset = 0
        while offset + n <= samples.count {
            var sum: Float = 0
            for k in offset..<(offset + n) { sum += samples[k] * samples[k] }
            if sum > 0 { levels.append((sum / Float(n)).squareRoot()) }
            offset += n
        }
        guard !levels.isEmpty else { return speechRmsCeiling }
        levels.sort()
        let reference = levels[min(levels.count - 1, Int(Double(levels.count) * 0.75))]
        return min(speechRmsCeiling, max(speechRmsFloor, reference * 0.3))
    }

    /// Seconds of frames above `threshold` between two sample offsets.
    static func speechSeconds(_ samples: [Float], from: Int, to: Int, threshold: Float) -> Double {
        let n = ParakeetTiming.samplesPerFrame
        var frames = 0
        var offset = from
        while offset + n <= to {
            var sum: Float = 0
            for k in offset..<(offset + n) { sum += samples[k] * samples[k] }
            if (sum / Float(n)).squareRoot() > threshold { frames += 1 }
            offset += n
        }
        return Double(frames) * ParakeetTiming.secondsPerFrame
    }

    /// The token bordering a gap, past punctuation (`step` -1 walks left).
    static func neighbor(_ tokens: [ParakeetToken], from index: Int, step: Int,
                         vocabulary: ParakeetVocabulary) -> ParakeetToken {
        var i = index
        while i + step >= 0, i + step < tokens.count,
              ParakeetVocabulary.isPunctuation(vocabulary[tokens[i].id] ?? "") {
            i += step
        }
        return tokens[i]
    }

    /// What a probe heard strictly inside a gap, starting on a word, less
    /// any re-heard copy of the words on either side.
    static func spliceCandidate(_ heard: [ParakeetToken], gapStart: Int, gapEnd: Int, lead: ParakeetToken,
                                tail: ParakeetToken, spliceSafe: Set<Int>,
                                vocabulary: ParakeetVocabulary) -> [ParakeetToken] {
        let edgeTolerance = 6
        func same(_ a: Int, _ b: Int) -> Bool {
            if a == b { return true }
            guard let pa = vocabulary[a], let pb = vocabulary[b] else { return false }
            return pa.lowercased() == pb.lowercased()
        }
        var candidate = heard.filter { $0.frame > gapStart && $0.frame < gapEnd - 1 }
        while let first = candidate.first, !spliceSafe.contains(first.id) { candidate.removeFirst() }
        while let first = candidate.first, same(first.id, lead.id), abs(first.frame - lead.frame) <= edgeTolerance {
            candidate.removeFirst()
        }
        while let last = candidate.last, same(last.id, tail.id), abs(tail.frame - last.frame) <= edgeTolerance {
            candidate.removeLast()
        }
        while let first = candidate.first,
              !spliceSafe.contains(first.id) || ParakeetVocabulary.isPunctuation(vocabulary[first.id] ?? "") {
            candidate.removeFirst()
        }
        return candidate
    }

    /// A gap worth probing: where it lies, and where to put the probes.
    struct Gap: Equatable {
        var after: Int
        var startFrame: Int
        var endFrame: Int
        /// Window starts to try in order: at the gap, then centred on it.
        var placements: [Int]
    }

    /// The gaps in `tokens` long enough, with enough speech, not yet probed.
    static func gaps(in tokens: [ParakeetToken], samples: [Float], threshold: Float,
                     probed: Set<Int>) -> [Gap] {
        let n = ParakeetTiming.samplesPerFrame
        let minGapFrames = max(2, Int(repairMinGapSeconds / ParakeetTiming.secondsPerFrame))
        var gaps: [Gap] = []
        guard tokens.count > 1 else { return gaps }
        for i in 0..<(tokens.count - 1) {
            let startFrame = tokens[i].frame + max(1, tokens[i].duration)
            let endFrame = tokens[i + 1].frame
            guard endFrame - startFrame >= minGapFrames, !probed.contains(startFrame) else { continue }
            let startSample = startFrame * n
            let endSample = min(endFrame * n, samples.count)
            guard endSample > startSample,
                  speechSeconds(samples, from: startSample, to: endSample, threshold: threshold)
                    >= repairMinSpeechSeconds else { continue }
            let centre = (startSample + endSample) / 2
            let placements = [startSample, centre - repairWindowSamples / 2].map { placement in
                max(0, min(placement, samples.count - repairWindowSamples)) / n * n
            }
            gaps.append(Gap(after: i, startFrame: startFrame, endFrame: endFrame, placements: placements))
        }
        return gaps
    }
}
