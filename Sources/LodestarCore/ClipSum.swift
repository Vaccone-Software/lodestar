import Foundation

/// A clip that is only arithmetic — "1234 * 1.08", "(12 + 7) / 3", "2^10",
/// "200 * 15%" — read as its answer.
///
/// Much that is digits and a dash or a slash is not a sum, so what counts
/// is narrow: at least one operator between two numbers, and a dash that is
/// the only operator must stand between spaces, so a phone number, a date,
/// an ID or a range (555-1234, 2026-09-25, 10-20) is never subtracted, and a
/// day and month (9/25, 24/7) is never divided. Multiplication is * or ×,
/// never x, so a size such as 1920x1080 stays a size.
public struct ClipSum: Equatable {
    public let value: Double

    private static let dayAndMonth = try! NSRegularExpression(pattern: #"^\d{1,2}/\d{1,2}(/\d{2,4})?$"#)

    public static func parse(_ text: String) -> ClipSum? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 3, s.count <= 80, !s.contains("\n") else { return nil }
        guard var tokens = tokenize(s) else { return nil }
        let binary = binaryOperators(tokens)
        guard !binary.isEmpty else { return nil }
        if binary.allSatisfy({ $0 == "-" }), !s.contains(" ") { return nil }
        if dayAndMonth.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return nil }
        guard let value = expression(&tokens), tokens.isEmpty, value.isFinite else { return nil }
        return ClipSum(value: value)
    }

    /// The answer, for the note's voice: grouped, to four places at most,
    /// and in scientific form past what a person reads as a number.
    public func voice(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        let size = abs(value)
        if size != 0, size >= 1e15 || size < 1e-4 {
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 6
        } else {
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 4
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Reading it

    enum Token: Equatable {
        case number(Double)
        case op(Character)
        case open, close
    }

    private static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == " " { i = s.index(after: i); continue }
            if c.isASCII, c.isNumber || c == "." {
                var end = i
                while end < s.endIndex, s[end].isASCII, s[end].isNumber || s[end] == "." || s[end] == "," {
                    end = s.index(after: end)
                }
                guard let number = number(String(s[i..<end])) else { return nil }
                tokens.append(.number(number))
                i = end
                continue
            }
            switch c {
            case "+", "-", "−", "*", "×", "/", "÷", "^", "%": tokens.append(.op(c == "−" ? "-" : c))
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: return nil
            }
            i = s.index(after: i)
        }
        return tokens
    }

    /// 1234.5, and 1,234.5 where the commas group thousands.
    private static func number(_ text: String) -> Double? {
        guard text.contains(",") else { return Double(text) }
        let groups = text.split(separator: ".")[0].split(separator: ",", omittingEmptySubsequences: false)
        guard groups.dropFirst().allSatisfy({ $0.count == 3 }), let first = groups.first, (1...3).contains(first.count)
        else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: ""))
    }

    /// The operators that stand between two operands.
    private static func binaryOperators(_ tokens: [Token]) -> [Character] {
        var found: [Character] = []
        var previous: Token?
        for token in tokens {
            if case .op(let c) = token, c != "%" {
                switch previous {
                case .number?, .close?, .op("%")?: found.append(c)
                default: break
                }
            }
            previous = token
        }
        return found
    }

    // expression := term (("+" | "-") term)*
    private static func expression(_ tokens: inout [Token]) -> Double? {
        guard var value = term(&tokens) else { return nil }
        while let first = tokens.first, first == .op("+") || first == .op("-") {
            tokens.removeFirst()
            guard let right = term(&tokens) else { return nil }
            value = first == .op("+") ? value + right : value - right
        }
        return value
    }

    // term := power (("*" | "×" | "/" | "÷") power)*
    private static func term(_ tokens: inout [Token]) -> Double? {
        guard var value = power(&tokens) else { return nil }
        while case .op(let c)? = tokens.first, "*×/÷".contains(c) {
            tokens.removeFirst()
            guard let right = power(&tokens) else { return nil }
            if c == "/" || c == "÷" {
                guard right != 0 else { return nil }
                value /= right
            } else {
                value *= right
            }
        }
        return value
    }

    // power := unary ("^" power)?, right to left
    private static func power(_ tokens: inout [Token]) -> Double? {
        guard let base = unary(&tokens) else { return nil }
        guard tokens.first == .op("^") else { return base }
        tokens.removeFirst()
        guard let exponent = power(&tokens) else { return nil }
        return pow(base, exponent)
    }

    // unary := "-" unary | primary "%"?
    private static func unary(_ tokens: inout [Token]) -> Double? {
        if tokens.first == .op("-") {
            tokens.removeFirst()
            return unary(&tokens).map { -$0 }
        }
        guard var value = primary(&tokens) else { return nil }
        if tokens.first == .op("%") {
            tokens.removeFirst()
            value /= 100
        }
        return value
    }

    // primary := number | "(" expression ")"
    private static func primary(_ tokens: inout [Token]) -> Double? {
        guard let first = tokens.first else { return nil }
        tokens.removeFirst()
        switch first {
        case .number(let value): return value
        case .open:
            guard let value = expression(&tokens), tokens.first == .close else { return nil }
            tokens.removeFirst()
            return value
        default: return nil
        }
    }
}

extension Clipboard.Clip {
    /// The answer this clip asks for, when it is only arithmetic.
    public var sum: ClipSum? {
        kind == .text ? ClipSum.parse(preview) : nil
    }
}
