import Foundation

extension Draft {
    /// Numbers as they are written, from numbers as they are said.
    ///
    /// Apple's recognizer writes "0.39.6" and "200" itself; the settling
    /// ears often spell them ("zero dot thirty nine dot six", "two hundred
    /// lines"). A version said with "dot" or "point" becomes digits, and a
    /// number said in two words or more, or worth ten or more, becomes
    /// digits too; "one of the" and "two files" stay words, the way they
    /// are written in prose.
    public enum SpokenNumbers {
        static let units: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
            "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ]
        static let tens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]
        static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]

        static func isNumberWord(_ word: String) -> Bool {
            units[word] != nil || tens[word] != nil || scales[word] != nil || Int(word) != nil
        }

        /// A run of number words as one value: "thirty nine" 39, "two
        /// hundred and five" 205. Nil when the run is not one number.
        static func value(_ words: [String]) -> Int? {
            guard !words.isEmpty else { return nil }
            if words.count == 1, let n = Int(words[0]) { return n }
            var total = 0, current = 0
            var last: String?
            for word in words {
                if let n = units[word] {
                    // "nine five" is two numbers, not one.
                    if let last, units[last] != nil { return nil }
                    current += n
                } else if let n = tens[word] {
                    if let last, units[last] != nil || tens[last] != nil { return nil }
                    current += n
                } else if let n = scales[word] {
                    current = max(1, current) * n
                    if n >= 1_000 { total += current; current = 0 }
                } else if let n = Int(word) {
                    guard last == nil else { return nil }
                    current = n
                } else {
                    return nil
                }
                last = word
            }
            return total + current
        }

        public static func written(_ text: String) -> String {
            var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var i = 0
            while i < tokens.count {
                // The longest run of number words (and "dot"/"point"/"and"
                // between them) from here, punctuation only at its end.
                var j = i
                var parts: [[String]] = [[]]
                var separators = 0
                var trail = ""
                let lead = NameMatcher.split(tokens[i]).lead
                while j < tokens.count {
                    let piece = NameMatcher.split(tokens[j])
                    if j > i, !piece.lead.isEmpty { break }
                    let word = piece.word.lowercased()
                    if isNumberWord(word) {
                        parts[parts.count - 1].append(word)
                    } else if (word == "dot" || word == "point"), !parts[parts.count - 1].isEmpty,
                              j + 1 < tokens.count, isNumberWord(NameMatcher.split(tokens[j + 1]).word.lowercased()),
                              piece.trail.isEmpty {
                        parts.append([])
                        separators += 1
                    } else if word == "and", !parts[parts.count - 1].isEmpty, parts[parts.count - 1].contains("hundred"),
                              j + 1 < tokens.count, piece.trail.isEmpty,
                              let next = units[NameMatcher.split(tokens[j + 1]).word.lowercased()] ?? tens[NameMatcher.split(tokens[j + 1]).word.lowercased()],
                              next > 0 {
                        // "two hundred and five"
                    } else {
                        break
                    }
                    trail = piece.trail
                    j += 1
                    if !trail.isEmpty { break }
                }
                let count = j - i
                guard count > 0 else { i += 1; continue }
                let values = parts.map(value)
                var replacement: String?
                if separators > 0, values.allSatisfy({ $0 != nil }) {
                    // A version or a decimal: each part as said, "thirty nine" → 39.
                    replacement = values.map { String($0!) }.joined(separator: ".")
                } else if separators == 0, let n = values[0], parts[0].count >= 2 || n >= 10,
                          parts[0].contains(where: { Int($0) == nil }),
                          // "a thousand thanks" stays words: a scale needs a number before it.
                          parts[0].contains(where: { units[$0] != nil || tens[$0] != nil }) {
                    replacement = String(n)
                }
                if let replacement {
                    tokens.replaceSubrange(i..<j, with: [lead + replacement + trail])
                }
                i += 1
            }
            return tokens.joined(separator: " ")
        }
    }
}
