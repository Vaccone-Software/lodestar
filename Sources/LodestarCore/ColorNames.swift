import Foundation

/// What a color is called: the nearest of the names people gave colors in
/// the xkcd survey, curated for a surface looked at every day (see
/// tools/color-names). Accurate first, because the survey placed each name
/// where people put it; character comes with the names themselves, Fire
/// Engine Red, Shamrock Green, Tangerine.
///
/// Near is measured in OKLab, where a distance is what the eye sees, with
/// three corrections for how people name a color:
///   hue first      lightness counts for less than hue, so a light orange
///                  is still called an orange, and a name more than 45°
///                  of hue away is never taken, so a dark teal is not brown
///   greys apart    a grey is named only by a grey, black or white, and a
///                  color never is; near black with a trace of tint is
///                  Almost Black, since no hue can be seen in it
///   vague last     a name that hedges (Lightish, Greeny) wins only when
///                  it is clearly the nearer
///
/// Measured over the whole RGB cube: the nearest name lies at a median of
/// 0.022, around one just-noticeable difference, with the far corners at
/// the very darkest colors.
public enum ColorNames {
    struct Entry {
        let name: String
        let lab: (l: Double, a: Double, b: Double)
        var chroma: Double { (lab.a * lab.a + lab.b * lab.b).squareRoot() }
        let vague: Bool
        let grey: Bool
    }

    static let entries: [Entry] = table.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t")
        guard parts.count == 2, let value = UInt32(parts[1], radix: 16) else { return nil }
        let name = String(parts[0])
        let words = Set(name.split(separator: " ").map(String.init))
        let lab = oklab(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                        blue: Double(value & 0xFF) / 255)
        return Entry(name: name, lab: lab,
                     vague: name.contains("ish ") || name.hasSuffix("ish")
                        || !words.isDisjoint(with: ["Orangey", "Browny", "Purpley", "Purply", "Greeny",
                                                    "Bluey", "Reddy", "Yellowy", "Pinky"]),
                     grey: !words.isDisjoint(with: ["Grey", "Black", "White", "Silver", "Charcoal"]))
    }

    /// A chroma below this has no hue to name.
    private static let neutral = 0.02
    private static let lightnessWeight = 0.6
    private static let vaguePenalty = 1.5
    private static let hueReach = 45.0

    public static func name(for color: ClipColor) -> String {
        let lab = oklab(red: color.red, green: color.green, blue: color.blue)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let grey = chroma < neutral || (lab.l < 0.2 && chroma < 0.04)
        let hue = atan2(lab.b, lab.a) * 180 / .pi
        var best: (distance: Double, name: String)?
        for entry in entries {
            if grey != (entry.grey && entry.chroma < neutral) { continue }
            if !grey, entry.chroma < neutral { continue }
            if !grey, chroma >= 0.025, entry.chroma >= 0.025 {
                var apart = abs(hue - atan2(entry.lab.b, entry.lab.a) * 180 / .pi)
                apart = min(apart, 360 - apart)
                if apart > hueReach { continue }
            }
            let dl = (lab.l - entry.lab.l) * lightnessWeight, da = lab.a - entry.lab.a, db = lab.b - entry.lab.b
            let distance = (dl * dl + da * da + db * db).squareRoot() * (entry.vague ? vaguePenalty : 1)
            if best == nil || distance < best!.distance { best = (distance, entry.name) }
        }
        return best?.name ?? (grey ? "Grey" : "Color")
    }

    /// sRGB (0...1) to OKLab (Björn Ottosson, 2020).
    static func oklab(red: Double, green: Double, blue: Double) -> (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

extension ClipColor {
    /// What the color is called, for the note on its card.
    public var name: String { ColorNames.name(for: self) }
}
