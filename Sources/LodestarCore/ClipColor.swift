import Foundation

/// A clip that is only a color — a hex a designer copied, an rgb() out of
/// a stylesheet — is shown as the color. The value is the whole clip or it
/// is not a color: a word in a sentence is a word.
public struct ClipColor: Equatable {
    /// 0...1 each.
    public let red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red); self.green = Self.unit(green)
        self.blue = Self.unit(blue); self.alpha = Self.unit(alpha)
    }

    private static func unit(_ value: Double) -> Double { min(1, max(0, value)) }

    /// The color as #RRGGBB, or #RRGGBBAA when it is not opaque.
    public var hex: String {
        let byte = { (v: Double) in String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    /// The CSS functional form, rgb() or rgb() with an alpha: the other
    /// notation a hex is shown beside.
    public var rgb: String {
        let byte = { (v: Double) in Int((v * 255).rounded()) }
        let base = "\(byte(red)), \(byte(green)), \(byte(blue))"
        return alpha < 1 ? "rgba(\(base), \(String(format: "%.2g", alpha)))" : "rgb(\(base))"
    }

    /// Relative luminance (WCAG), for choosing text that reads on it.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The color a clip's text is, or nil. Recognized, the whole text (a
    /// trailing semicolon aside):
    ///   #RRGGBB #RRGGBBAA              hex, any case
    ///   #RGB #RGBA                     with a letter in it: #123 is an issue
    ///   RRGGBB                         bare, as design tools copy it, with a
    ///                                  letter, and a digit or in capitals:
    ///                                  123456 is a number, facade a word,
    ///                                  and eight bare digits are a hash
    ///   0xRRGGBB                       as code writes it
    ///   rgb() rgba() hsl() hsla()      CSS, comma or space syntax, / alpha
    public static func parse(_ text: String) -> ClipColor? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        guard !s.isEmpty, s.count <= 64, !s.contains("\n") else { return nil }
        let lower = s.lowercased()
        let hasLetter = { (t: String) in t.contains(where: { "abcdef".contains($0) }) }
        if lower.hasPrefix("#") {
            let digits = String(lower.dropFirst())
            if digits.count <= 4, !hasLetter(digits) { return nil }
            return hex(digits, allowShort: true)
        }
        if lower.hasPrefix("0x"), lower.count == 8 { return hex(String(lower.dropFirst(2)), allowShort: false) }
        if s.count == 6, hasLetter(lower), s.contains(where: \.isNumber) || s == s.uppercased() {
            return hex(lower, allowShort: false)
        }
        for name in ["rgba", "rgb", "hsla", "hsl"] where lower.hasPrefix(name + "(") && lower.hasSuffix(")") {
            let inner = lower.dropFirst(name.count + 1).dropLast()
            return functional(name.hasPrefix("rgb") ? "rgb" : "hsl", String(inner))
        }
        return nil
    }

    private static func hex(_ digits: String, allowShort: Bool) -> ClipColor? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        var full = digits
        if allowShort, digits.count == 3 || digits.count == 4 {
            full = digits.map { "\($0)\($0)" }.joined()
        }
        guard full.count == 6 || full.count == 8, let value = UInt64(full, radix: 16) else { return nil }
        let byte = { (shift: UInt64) in Double((value >> shift) & 0xFF) / 255 }
        return full.count == 6
            ? ClipColor(red: byte(16), green: byte(8), blue: byte(0))
            : ClipColor(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
    }

    /// `rgb(255, 79, 0)`, `rgb(255 79 0 / 50%)`, `hsl(19deg 100% 50%)`.
    private static func functional(_ kind: String, _ inner: String) -> ClipColor? {
        var alphaPart: String?
        var body = inner
        if let slash = inner.firstIndex(of: "/") {
            alphaPart = String(inner[inner.index(after: slash)...])
            body = String(inner[..<slash])
        }
        var parts = body.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        if alphaPart == nil, parts.count == 4 { alphaPart = parts.removeLast() }
        guard parts.count == 3 else { return nil }
        let alpha = alphaPart.map { number($0.trimmingCharacters(in: .whitespaces), percentOf: 1) } ?? 1
        guard let alpha else { return nil }
        if kind == "rgb" {
            let channels = parts.map { number($0, percentOf: 255) }
            guard let r = channels[0], let g = channels[1], let b = channels[2] else { return nil }
            return ClipColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
        }
        let hue = parts[0].replacingOccurrences(of: "deg", with: "")
        guard let h = Double(hue), let s = number(parts[1], percentOf: 1), let l = number(parts[2], percentOf: 1),
              parts[1].hasSuffix("%"), parts[2].hasSuffix("%") else { return nil }
        return hsl(h, s, l, alpha)
    }

    /// A number, or a percentage of `scale`.
    private static func number(_ text: String, percentOf scale: Double) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 * scale } }
        return Double(text)
    }

    private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double, _ alpha: Double) -> ClipColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double)
        switch Int(h * 6) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return ClipColor(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }
}

extension Clipboard.Clip {
    /// The color this clip is, when it is only one.
    public var color: ClipColor? {
        kind == .text ? ClipColor.parse(preview) : nil
    }
}
