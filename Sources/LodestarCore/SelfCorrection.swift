import Foundation

extension Draft {
    /// What a speaker takes back while talking, taken out.
    ///
    /// Two fixed rules, no model. Fillers ("um", "uh") go when they stand
    /// alone. A strong cue — "no wait", "scratch that", "sorry, I mean",
    /// "or rather" — removes the words it corrects and the cue itself:
    /// "send it Monday, no wait, I mean Tuesday" lands "send it Tuesday".
    /// Measured on the dictation set, the cue rule halved the distance
    /// to what was meant and never fired on 40 clips of ordinary speech.
    /// A model that repaired freely added nothing past the rule and
    /// sometimes changed meaning; the one that runs after it, the intent
    /// pass (`IntentPass`), is held by a checker to deletions and writing.
    public enum SelfCorrection {
        public struct Result: Equatable, Sendable {
            public let text: String
            /// How many fillers and corrections were taken out, for the
            /// record. Never the words.
            public let fillers: Int
            public let corrections: Int
        }

        public static func apply(_ text: String) -> Result {
            let (unfilled, fillers) = withoutFillers(text)
            var out = unfilled
            var corrections = 0
            for _ in 0..<4 {
                guard let next = repairOnce(out) else { break }
                out = next
                corrections += 1
            }
            return Result(text: out, fillers: fillers, corrections: corrections)
        }

        // MARK: - Fillers

        private static let filler = try! NSRegularExpression(
            pattern: #"(?:,\s*|\s+|^)(?:um+|uh+|uhm+|erm+|hmm+)(?=$|[\s,.;!?]),?"#, options: [.caseInsensitive])

        static func withoutFillers(_ text: String) -> (String, Int) {
            let ns = text as NSString
            let matches = filler.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return (text, 0) }
            let out = NSMutableString(string: text)
            for match in matches.reversed() {
                out.replaceCharacters(in: match.range, with: " ")
            }
            var result = (out as String)
                .replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            while result.hasPrefix(",") || result.hasPrefix(".") {
                result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // A filler that opened the text took its capital with it.
            if let first = result.first, first.isLowercase, let original = text.first, original.isUppercase {
                result = first.uppercased() + result.dropFirst()
            }
            return (result, matches.count)
        }

        // MARK: - Cues

        private static let between = #"[,.]?\s+"#
        private static let scratch = try! NSRegularExpression(
            pattern: #"[,.;]?\s*\b(?:scratch that|never mind|forget that)\b[,.;]?\s*"#, options: [.caseInsensitive])
        private static let repair = try! NSRegularExpression(
            pattern: #"[,.;]?\s*\b(?:no"# + between + #"wait(?:"# + between + #"I mean)?|wait"# + between
                + #"no|no"# + between + #"I mean|sorry"# + between + #"I mean|or rather|or actually|no"#
                + between + #"actually)\b[,.;]?\s*"#,
            options: [.caseInsensitive])
        private static let sorry = try! NSRegularExpression(pattern: #"[,.]\s+sorry[,.]\s+"#, options: [.caseInsensitive])
        private static let boundary: Set<String> = Set("""
            to of in on at for with by from into onto about over under is are was were be the a an and or but than as via
            """.split(whereSeparator: \.isWhitespace).map(String.init))

        static func repairOnce(_ text: String) -> String? {
            let ns = text as NSString
            let all = NSRange(location: 0, length: ns.length)
            for (kind, pattern) in [("scratch", scratch), ("repair", repair), ("sorry", sorry)] {
                guard let match = pattern.firstMatch(in: text, range: all) else { continue }
                var start = sentenceStart(ns, before: match.range.location)
                if ns.substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespaces).isEmpty, start > 0 {
                    // The recognizer ended the sentence right before the cue.
                    start = sentenceStart(ns, before: start - 1)
                }
                var pre = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                let after = ns.substring(from: match.range.location + match.range.length)
                pre = pre.replacingOccurrences(of: #"[.!?]\s*$"#, with: "", options: .regularExpression)
                let head = ns.substring(to: start)
                if kind == "scratch" {
                    return head + capitalized(after)
                }
                let preWords = pre.split(separator: " ").map(String.init)
                let chunk = after.split(maxSplits: 1, whereSeparator: { ",.;!?".contains($0) }).first.map(String.init) ?? ""
                let repairWords = Array(chunk.split(separator: " ").map { normal(String($0)) }.prefix(6))
                let preNormal = preWords.map(normal)
                guard let cut = cutPoint(pre: preNormal, repair: repairWords) else { return nil }
                let kept = preWords.prefix(cut).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                return head + (kept.isEmpty ? capitalized(after) : kept + " " + after)
            }
            return nil
        }

        /// Where the words being corrected begin, or nil when the rule is
        /// unsure and leaves the text alone.
        static func cutPoint(pre: [String], repair: [String]) -> Int? {
            // The repair repeats the words before the cue, after one
            // replaced word ("delete the old, no wait, archive the old").
            if repair.count > 1 {
                for j in stride(from: min(pre.count, repair.count - 1), through: 1, by: -1)
                where Array(pre.suffix(j)) == Array(repair[1..<(1 + j)]) {
                    return max(0, pre.count - j - 1)
                }
                // Its second word occurs in the last four words before it:
                // the replaced phrase starts one word before that.
                for p in stride(from: pre.count - 1, to: max(-1, pre.count - 5), by: -1)
                where p > 0 && pre[p] == repair[1] {
                    return p - 1
                }
            }
            // It restarts with the words before the cue ("when, um, when Raycast").
            if !repair.isEmpty {
                for j in stride(from: min(pre.count, repair.count), through: 1, by: -1)
                where Array(pre.suffix(j)) == Array(repair.prefix(j)) {
                    return pre.count - j
                }
            }
            // It begins with a boundary word that occurs before the cue
            // ("on Slack, or actually on Telegram").
            if let first = repair.first, boundary.contains(first), let at = pre.lastIndex(of: first) {
                return at
            }
            // Otherwise the words after the last boundary word, at most three.
            var k = pre.count
            while k > 0, !boundary.contains(pre[k - 1]), pre.count - k < 3 { k -= 1 }
            if k > 0, !boundary.contains(pre[k - 1]) { return nil }
            return k
        }

        static func sentenceStart(_ text: NSString, before location: Int) -> Int {
            let regex = try! NSRegularExpression(pattern: #"[.!?]\s+"#)
            var start = 0
            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: max(0, location))) {
                start = match.range.location + match.range.length
            }
            return start
        }

        static func normal(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "." }
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        static func capitalized(_ text: String) -> String {
            guard let first = text.first, first.isLowercase else { return text }
            return first.uppercased() + text.dropFirst()
        }
    }
}
