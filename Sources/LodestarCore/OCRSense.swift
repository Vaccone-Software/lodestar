import CoreGraphics
import Foundation
import ImageIO
import Vision

/// The pixel sensor: what select sees when it looks at a window.
///
/// Pixels are the one interface every window implements. Accessibility
/// trees build lazily, un-build after idle, answer geometry per-app
/// per-element per-mood, and draw element boundaries a span cannot cross
/// — every one of which was a measured source of inconsistency. The
/// screen itself has none of those properties: the Vision framework reads
/// the capture, returns each visual line with its geometry, and can place
/// any character range of a line to the pixel. Recognition is configured
/// for fidelity over fluency: accurate level, language correction OFF —
/// correction "fixes" identifiers, and a copied UUID must be the UUID.
///
/// System framework, so the zero-dependency rule stands.
public enum OCRSense {
    /// One recognized visual line, in screen (Quartz, top-left origin)
    /// coordinates.
    public struct Line {
        public let text: String
        public let frame: CGRect
        let candidate: VNRecognizedText
        let windowFrame: CGRect

        /// Screen rectangles for a UTF-16 range of this line's text —
        /// character-precise, straight from the recognizer.
        public func rects(for range: NSRange) -> [CGRect] {
            guard let stringRange = Range(range, in: text) else { return [] }
            guard let observation = try? candidate.boundingBox(for: stringRange) else {
                return [frame]
            }
            return [OCRSense.mapped(observation.boundingBox, in: windowFrame)]
        }
    }

    /// Vision's normalized bottom-left box → Quartz screen rect.
    static func mapped(_ box: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + box.minX * windowFrame.width,
               y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
               width: box.width * windowFrame.width,
               height: box.height * windowFrame.height)
    }

    public enum Level {
        /// ~100ms on a Retina display: the world appears at once, rough
        /// around rare glyphs.
        case fast
        /// The truth, a few hundred milliseconds later — always run, and
        /// always the pass a copy is served from.
        case accurate
    }

    /// Recognize every line of a capture. Synchronous and CPU-fed — call
    /// off the main thread. Runs twice per mode entry over one frozen
    /// frame: fast to be present, accurate to be right, the second
    /// replacing the first the way every richer pass here replaces a
    /// poorer one.
    public static func recognize(image: CGImage, windowFrame: CGRect,
                                 level: Level = .accurate) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return Line(text: candidate.string,
                        frame: mapped(observation.boundingBox, in: windowFrame),
                        candidate: candidate,
                        windowFrame: windowFrame)
        }
    }

    /// What an image says, for a clipboard card to be found by: every
    /// line the accurate pass reads, top to bottom then left to right.
    /// Decodes the image once, off whatever thread calls it — never the
    /// main one — and answers nil when nothing was read or the bytes are
    /// not a picture.
    public static func readText(imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let lines = recognize(image: image, windowFrame: frame, level: .accurate)
        guard !lines.isEmpty else { return nil }
        let sorted = lines.sorted { a, b in
            let dy = a.frame.minY - b.frame.minY
            if abs(dy) > 4 { return dy < 0 }
            return a.frame.minX < b.frame.minX
        }
        return sorted.map(\.text).joined(separator: "\n")
    }

    /// Whitespace-collapsed form, for grounding an OCR span against
    /// accessibility ground truth: recognition and AX may disagree about
    /// runs of spaces, never about the words between them.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The accessibility-read truth, normalized once and kept.
    ///
    /// Recognition of clean screen text is nearly perfect — nearly. The
    /// residue is single-glyph confusion (`1`↔`l`, `0`↔`O`), which is
    /// harmless in prose and catastrophic in an identifier: a copied
    /// token that is one silent character wrong burns a user worse than
    /// no copy at all. So when AX could read the same region, its text is
    /// the truth.
    ///
    /// Prepared rather than free-standing because normalizing the
    /// candidates is the expensive half, and a span crossing runs asks
    /// for a repair once per piece — the preparation belongs to the
    /// harvest that produced the texts, off the main thread, not to the
    /// keystroke that commits.
    public struct Grounding {
        let haystacks: [String]

        public init(_ candidates: [String]) {
            haystacks = candidates.map(OCRSense.normalized)
        }

        /// The truth behind a recognized span, or nil to keep the pixels.
        /// An exact match confirms the span; failing that, the span is
        /// aligned by a long word and repaired when the accessibility
        /// window agrees at the same length with only a few substituted
        /// characters. Anything less similar is left alone — a grounding
        /// that guessed would be the worse corruption.
        public func repair(_ span: String) -> String? {
            let target = normalized(span)
            guard target.count >= 4 else { return nil }
            for haystack in haystacks where haystack.contains(target) {
                return span
            }
            // Any word can anchor the alignment — tried longest first,
            // because longer anchors misalign less. Crucially not ONLY
            // the longest: the longest word is usually the identifier,
            // and the identifier is usually the thing that was misread,
            // so the anchor that works is a clean ordinary word beside it.
            let anchors = target.split(separator: " ")
                .filter { $0.count >= 5 }
                .sorted { $0.count > $1.count }
            for anchor in anchors {
                guard let targetAnchor = target.range(of: String(anchor)) else { continue }
                let lead = target.distance(from: target.startIndex,
                                           to: targetAnchor.lowerBound)
                // Every occurrence of the anchor, in every haystack — the
                // first occurrence alone once repaired "value: 4821" from
                // an earlier "value: 4826" and called it truth. An exact
                // window anywhere confirms the span; a repair is taken
                // only when exactly one candidate passes, because two
                // passing windows that disagree is a guess, and a
                // grounding that guessed would be the worse corruption.
                var candidates: Set<String> = []
                for haystack in haystacks {
                    var from = haystack.startIndex
                    while let anchorRange = haystack.range(of: String(anchor),
                                                           range: from..<haystack.endIndex) {
                        from = haystack.index(after: anchorRange.lowerBound)
                        guard let start = haystack.index(anchorRange.lowerBound,
                                                         offsetBy: -lead,
                                                         limitedBy: haystack.startIndex),
                              let end = haystack.index(start, offsetBy: target.count,
                                                       limitedBy: haystack.endIndex)
                        else { continue }
                        let window = String(haystack[start..<end])
                        guard window.count == target.count else { continue }
                        let mismatches = zip(window, target).filter { $0.0 != $0.1 }.count
                        if mismatches == 0 { return span }
                        if Double(mismatches) / Double(target.count) <= 0.15 {
                            candidates.insert(window)
                        }
                    }
                }
                guard candidates.isEmpty else {
                    // The window is the haystack's normalized text: one
                    // line, spaces collapsed. Substituting it under a
                    // multi-line span would paste one long line while
                    // three stand lit — the highlight is the promise, so
                    // a span with a newline is confirmed or left alone.
                    guard !span.contains("\n"), candidates.count == 1 else { return nil }
                    return candidates.first
                }
            }
            return nil
        }
    }

    /// Ground one span against candidates prepared on the spot.
    public static func ground(_ span: String, in candidates: [String]) -> String? {
        Grounding(candidates).repair(span)
    }

    // MARK: - The copy's second readings

    /// The glyph classes recognition confuses on clean screen text, folded
    /// to one representative each, case dropped: what two readings of the
    /// same span must agree on is everything but these.
    static func foldConfusables(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var previous: Character?
        for character in text.lowercased() {
            let folded: Character
            switch character {
            case "l", "i", "|", "1", "!", "í", "ì": folded = "1"
            case "o", "0", "ø", "º": folded = "0"
            case "s", "5", "$": folded = "5"
            case "z", "2": folded = "2"
            case "b", "8": folded = "8"
            case "g", "6", "9", "q": folded = "6"
            case "\u{2018}", "\u{2019}", "`", "'": folded = "'"
            case "\u{201C}", "\u{201D}", "\"": folded = "\""
            case "\u{2013}", "\u{2014}", "-", "_": folded = "-"
            case ",", ".": folded = "."
            default: folded = character
            }
            // rn reads as m and m as rn: both become m.
            if folded == "n", previous == "r" {
                out.removeLast()
                out.append("m")
                previous = "m"
                continue
            }
            out.append(folded)
            previous = folded
        }
        return out
    }

    /// Does a second reading confirm the first? Agreement is equality up
    /// to the confusable classes and whitespace, with an edit distance
    /// small against the length: a drag that grabbed a neighboring span
    /// or a line more is a disagreement, and the first reading stands.
    public static func agrees(_ first: String, _ second: String) -> Bool {
        let a = foldConfusables(normalized(first))
        let b = foldConfusables(normalized(second))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let allowance = max(1, a.count / 10)
        guard abs(a.count - b.count) <= allowance else { return false }
        return editDistance(Array(a), Array(b), cap: allowance) <= allowance
    }

    /// The app's copy of a span, cut to the span the pixels promised.
    ///
    /// A drag's ends land a pixel or two off, and the app then copies a
    /// character more at either end — a period, a bracket. The app's
    /// glyphs are the truth and the pixels' extent is the promise, so
    /// the two are aligned through the confusable fold, whitespace
    /// aside: the pixel span found inside the app's copy names the
    /// slice of the app's own text that stands. A copy that does not
    /// contain the span is accepted only as a glyph-for-glyph
    /// substitution — the same count, few edits — and otherwise refused.
    public static func reconcile(pixel: String, app: String) -> String? {
        let appGlyphs = foldedGlyphs(app)
        let pixelGlyphs = foldedGlyphs(pixel)
        guard !appGlyphs.isEmpty, !pixelGlyphs.isEmpty else { return nil }
        let a = appGlyphs.map(\.glyph)
        let p = pixelGlyphs.map(\.glyph)
        if p.count <= a.count {
            for offset in 0...(a.count - p.count) where Array(a[offset..<offset + p.count]) == p {
                let start = appGlyphs[offset].range.lowerBound
                let end = appGlyphs[offset + p.count - 1].range.upperBound
                return String(app[start..<end])
            }
        }
        guard a.count == p.count else { return nil }
        let allowance = max(1, p.count / 10)
        return editDistance(a, p, cap: allowance) <= allowance ? app : nil
    }

    /// The confusable-folded glyphs of a text with the range each came
    /// from, whitespace dropped. `rn` folds to one glyph spanning both.
    static func foldedGlyphs(_ text: String) -> [(glyph: Character, range: Range<String.Index>)] {
        var out: [(glyph: Character, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isWhitespace { index = next; continue }
            let folded = foldConfusables(String(character)).first ?? character
            if folded == "n", let last = out.last, last.glyph == "r" {
                out[out.count - 1] = (glyph: "m", range: last.range.lowerBound..<next)
            } else {
                out.append((glyph: folded, range: index..<next))
            }
            index = next
        }
        return out
    }

    /// Levenshtein with a cap: past `cap` the exact value is not needed.
    static func editDistance(_ x: [Character], _ y: [Character], cap: Int) -> Int {
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// A token that is digits with a lone letter from the confusable set
    /// is a number the recognizer misread: `2O24` is 2024, `1l0` is 110.
    /// The other direction — letters carrying a lone digit — is left
    /// alone, because identifiers carry digits on purpose and `v2l`
    /// must stay `v2l`. Repairs land inside tokens only; nothing moves.
    public static func repairTokens(_ text: String) -> String {
        var out = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            let digits = token.filter(\.isNumber).count
            let letters = token.filter(\.isLetter).count
            let confusable = token.filter { "lIOo".contains($0) }.count
            if letters > 0, confusable == letters, digits >= 2 * letters {
                token = String(token.map { character -> Character in
                    switch character {
                    case "l", "I": return "1"
                    case "O", "o": return "0"
                    default: return character
                    }
                })
            }
            out += token
            token = ""
        }
        for character in text {
            if character.isLetter || character.isNumber { token.append(character) } else { flush(); out.append(character) }
        }
        flush()
        return out
    }

    /// Among a recognizer's candidates for one line, the one whose
    /// tokens are shaped like tokens, then repaired. A tie keeps the top
    /// candidate: the recognizer's order is evidence too.
    public static func resolveConfusables(_ candidates: [String]) -> String? {
        guard let first = candidates.first else { return nil }
        func penalty(_ text: String) -> Int {
            var total = 0
            var token = ""
            func score() {
                let digits = token.filter(\.isNumber).count
                let letters = token.filter(\.isLetter).count
                if digits > 0, letters > 0 {
                    let confusableLetters = token.filter { "lIOo".contains($0) }.count
                    let confusableDigits = token.filter { "01".contains($0) }.count
                    if confusableLetters == letters, digits >= 2 * letters { total += letters }
                    if confusableDigits == digits, letters >= 2 * digits { total += digits }
                }
                token = ""
            }
            for character in text {
                if character.isLetter || character.isNumber { token.append(character) } else { score() }
            }
            score()
            return total
        }
        var best = first
        var bestPenalty = penalty(first)
        for candidate in candidates.dropFirst() {
            let value = penalty(candidate)
            if value < bestPenalty { best = candidate; bestPenalty = value }
        }
        return repairTokens(best)
    }

    /// A second reading of one span: its rectangle cropped from the
    /// frozen frame, upscaled, and recognized at the accurate level with
    /// the recognizer's alternatives consulted. Tens of milliseconds for
    /// a line, and never on the aiming path — only what leaves the
    /// clipboard is read twice.
    public static func reread(image: CGImage, rect: CGRect, windowFrame: CGRect,
                              scale: CGFloat = 3) -> String? {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / windowFrame.width
        let sy = CGFloat(image.height) / windowFrame.height
        let pad: CGFloat = 4
        let crop = CGRect(x: (rect.minX - windowFrame.minX - pad) * sx,
                          y: (rect.minY - windowFrame.minY - pad) * sy,
                          width: (rect.width + pad * 2) * sx,
                          height: (rect.height + pad * 2) * sy)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, crop.width >= 4, crop.height >= 4,
              let cropped = image.cropping(to: crop) else { return nil }
        let width = Int(CGFloat(cropped.width) * scale)
        let height = Int(CGFloat(cropped.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let big = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: big, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty else { return nil }
        // The recognizer may hand one line back in fragments, split at an
        // underscore or a run of punctuation. Fragments on one line are
        // ordered left to right and joined by their gap — touching
        // fragments run together, a space's width apart gets a space —
        // and lines run top to bottom. Vision's boxes have a bottom-left
        // origin.
        let sorted = observations.sorted { a, b in
            let tolerance = max(a.boundingBox.height, b.boundingBox.height) * 0.5
            if abs(a.boundingBox.midY - b.boundingBox.midY) > tolerance {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        var lines: [String] = []
        var previous: VNRecognizedTextObservation?
        for observation in sorted {
            guard let text = resolveConfusables(observation.topCandidates(3).map(\.string)),
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let previous,
               abs(previous.boundingBox.midY - observation.boundingBox.midY)
                   <= max(previous.boundingBox.height, observation.boundingBox.height) * 0.5 {
                let gap = observation.boundingBox.minX - previous.boundingBox.maxX
                let spaceWidth = observation.boundingBox.height * 0.3
                lines[lines.count - 1] += (gap > spaceWidth ? " " : "") + text
            } else {
                lines.append(text)
            }
            previous = observation
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The second reading laid over the first: glyph for glyph, keeping
    /// the first reading's spaces and line breaks exactly. A reading
    /// with a different number of glyphs is refused — it read a
    /// different span, or split a word — so a re-read can change a
    /// letter and never the shape of what the highlight promised.
    public static func overlay(reading: String, onto first: String) -> String? {
        let glyphs = Array(reading.filter { !$0.isWhitespace })
        var out = ""
        var index = 0
        for character in first {
            if character.isWhitespace {
                out.append(character)
            } else {
                guard index < glyphs.count else { return nil }
                out.append(glyphs[index])
                index += 1
            }
        }
        return index == glyphs.count ? out : nil
    }
}
