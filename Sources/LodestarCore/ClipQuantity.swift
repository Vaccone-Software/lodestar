import Foundation

/// A clip that is only a measurement — "5 km", "72°F", "6 ft 2 in", "500 mL"
/// — read into your units. A measurement already in your units has nothing
/// to read and is left a plain card; one in the other system gets a note
/// with what it is in yours, in the unit a person would reach for: inches
/// become centimeters and miles kilometers, a height in centimeters becomes
/// feet and inches.
public struct ClipQuantity: Equatable {
    public enum System: String, Equatable, CaseIterable {
        case metric, imperial

        /// The system a region measures in: the United States (and the
        /// few places the Mac lists with it) imperial, everywhere else
        /// metric, the United Kingdom included.
        public static func regional(_ locale: Locale = .current) -> System {
            locale.measurementSystem == .us ? .imperial : .metric
        }

        /// The setting's system, or the region's while none is chosen.
        public static func chosen(_ setting: String, locale: Locale = .current) -> System {
            System(rawValue: setting) ?? regional(locale)
        }
    }

    public let value: Double
    public let unit: Dimension
    public let system: System

    /// The measurement a clip's text is, or nil. The whole text: a number,
    /// then a unit, or feet then inches. A unit that is also a word or a
    /// letter ("m", "g", "l") needs its space: 10m is ten minutes in a log.
    public static func parse(_ text: String) -> ClipQuantity? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 40, !s.contains("\n") else { return nil }
        if let height = feetAndInches(s) { return height }
        var end = s.startIndex
        if s.hasPrefix("-") { end = s.index(after: end) }
        while end < s.endIndex, s[end].isASCII, s[end].isNumber || s[end] == "." || s[end] == "," {
            end = s.index(after: end)
        }
        guard let value = number(String(s[..<end])) else { return nil }
        let rest = s[end...]
        let spaced = rest.first == " "
        let token = rest.trimmingCharacters(in: .whitespaces)
        guard let entry = units[token] ?? units[token.lowercased()], spaced || !entry.spaced else { return nil }
        // Below zero only as a temperature: "-5 km" is a typo or a range.
        if value < 0, !(entry.unit is UnitTemperature) { return nil }
        return ClipQuantity(value: value, unit: entry.unit, system: entry.system)
    }

    /// 1,500 and 2.5, and 2,5 as the comma-decimal regions write it.
    private static func number(_ text: String) -> Double? {
        guard text.contains(where: \.isNumber) else { return nil }
        var t = text
        let commas = t.filter { $0 == "," }.count
        if commas == 1, !t.contains("."), let comma = t.firstIndex(of: ","),
           t.distance(from: comma, to: t.endIndex) - 1 < 3 {
            t = t.replacingOccurrences(of: ",", with: ".")
        } else if commas > 0 {
            // Grouping only where it groups thousands.
            let groups = t.split(separator: ".")[0].split(separator: ",", omittingEmptySubsequences: false)
            guard groups.dropFirst().allSatisfy({ $0.count == 3 }), (groups.first?.count ?? 0) <= 4 else { return nil }
            t = t.replacingOccurrences(of: ",", with: "")
        }
        return Double(t)
    }

    private static let heightPattern = try! NSRegularExpression(
        pattern: #"^(\d+)\s*(?:'|′|ft|feet|foot)\s*(\d+(?:\.\d+)?)\s*(?:"|″|in|inch|inches)?$"#)

    /// 6'2", 6′ 2″, 6 ft 2 in, 5'11.
    private static func feetAndInches(_ s: String) -> ClipQuantity? {
        let range = NSRange(s.startIndex..., in: s)
        guard let match = heightPattern.firstMatch(in: s, range: range),
              let feet = Range(match.range(at: 1), in: s).flatMap({ Double(s[$0]) }),
              let inches = Range(match.range(at: 2), in: s).flatMap({ Double(s[$0]) }), inches < 12
        else { return nil }
        return ClipQuantity(value: feet * 12 + inches, unit: UnitLength.inches, system: .imperial)
    }

    private struct Entry {
        let unit: Dimension
        let system: System
        /// Written after a space only: a letter that is also a word.
        let spaced: Bool
    }

    private static let units: [String: Entry] = {
        var table: [String: Entry] = [:]
        func add(_ unit: Dimension, _ system: System, _ names: [String], spaced: Bool = false) {
            for name in names { table[name] = Entry(unit: unit, system: system, spaced: spaced) }
        }
        add(UnitLength.millimeters, .metric, ["mm", "millimeter", "millimeters", "millimetre", "millimetres"])
        add(UnitLength.centimeters, .metric, ["cm", "centimeter", "centimeters", "centimetre", "centimetres"])
        add(UnitLength.meters, .metric, ["m"], spaced: true)
        add(UnitLength.meters, .metric, ["meter", "meters", "metre", "metres"])
        add(UnitLength.kilometers, .metric, ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        add(UnitLength.inches, .imperial, ["in"], spaced: true)
        add(UnitLength.inches, .imperial, ["\"", "″", "inch", "inches"])
        add(UnitLength.feet, .imperial, ["ft", "'", "′", "foot", "feet"])
        add(UnitLength.yards, .imperial, ["yd", "yds", "yard", "yards"])
        add(UnitLength.miles, .imperial, ["mi", "mile", "miles"])
        add(UnitMass.milligrams, .metric, ["mg", "milligram", "milligrams"])
        add(UnitMass.grams, .metric, ["g"], spaced: true)
        add(UnitMass.grams, .metric, ["gram", "grams"])
        add(UnitMass.kilograms, .metric, ["kg", "kilogram", "kilograms", "kilo", "kilos"])
        add(UnitMass.ounces, .imperial, ["oz", "ounce", "ounces"])
        add(UnitMass.pounds, .imperial, ["lb", "lbs", "pound", "pounds"])
        add(UnitVolume.milliliters, .metric, ["ml", "mL", "milliliter", "milliliters", "millilitre", "millilitres"])
        add(UnitVolume.liters, .metric, ["L", "liter", "liters", "litre", "litres"])
        add(UnitVolume.liters, .metric, ["l"], spaced: true)
        add(UnitVolume.fluidOunces, .imperial, ["fl oz", "fl. oz.", "fluid ounce", "fluid ounces"])
        add(UnitVolume.cups, .imperial, ["cup", "cups"])
        add(UnitVolume.pints, .imperial, ["pt", "pint", "pints"])
        add(UnitVolume.quarts, .imperial, ["qt", "quart", "quarts"])
        add(UnitVolume.gallons, .imperial, ["gal", "gallon", "gallons"])
        add(UnitVolume.teaspoons, .imperial, ["tsp", "teaspoon", "teaspoons"])
        add(UnitVolume.tablespoons, .imperial, ["tbsp", "tablespoon", "tablespoons"])
        add(UnitTemperature.celsius, .metric, ["°C", "ºC", "℃", "° C", "celsius", "degrees celsius"])
        add(UnitTemperature.fahrenheit, .imperial, ["°F", "ºF", "℉", "° F", "fahrenheit", "degrees fahrenheit"])
        add(UnitSpeed.kilometersPerHour, .metric, ["km/h", "kph", "kmh"])
        add(UnitSpeed.milesPerHour, .imperial, ["mph"])
        add(UnitArea.squareCentimeters, .metric, ["cm²", "cm2", "sq cm"])
        add(UnitArea.squareMeters, .metric, ["m²", "m2", "sq m"])
        add(UnitArea.squareKilometers, .metric, ["km²", "km2", "sq km"])
        add(UnitArea.hectares, .metric, ["ha", "hectare", "hectares"])
        add(UnitArea.squareInches, .imperial, ["in²", "sq in"])
        add(UnitArea.squareFeet, .imperial, ["ft²", "ft2", "sq ft", "sqft"])
        add(UnitArea.squareMiles, .imperial, ["mi²", "sq mi"])
        add(UnitArea.acres, .imperial, ["acre", "acres"])
        return table
    }()

    // MARK: - The note

    /// What the measurement is in `system`, for the card's note: the voice
    /// says it at three figures in the unit a person reaches for, and a
    /// height in feet and inches or a temperature rounded to the degree
    /// carries its exact value beneath. Nil when it is already in `system`.
    public func note(into system: System, locale: Locale = .current) -> (voice: String, exact: String?)? {
        guard system != self.system else { return nil }
        let from = Measurement(value: value, unit: unit)
        if system == .imperial, unit is UnitLength,
           case let inches = from.converted(to: UnitLength.inches).value, inches >= 12, inches < 120 {
            var feet = Int(inches / 12), rest = Int((inches - Double(feet) * 12).rounded())
            if rest == 12 { feet += 1; rest = 0 }
            return ("\(feet)′ \(rest)″", format(Measurement(value: inches, unit: UnitLength.inches), locale: locale))
        }
        let target = Self.target(for: unit, value: from, into: system)
        let converted = from.converted(to: target)
        if target is UnitTemperature {
            let voice = format(converted, digits: 0, locale: locale), exact = format(converted, digits: 1, locale: locale)
            return (voice, exact == voice ? nil : exact)
        }
        return (format(converted, locale: locale), nil)
    }

    /// The unit a person reaches for on the other side, chosen by the unit
    /// the clip was written in and, where one unit is too coarse, by size.
    private static func target(for unit: Dimension, value: Measurement<Dimension>, into system: System) -> Dimension {
        switch (unit, system) {
        case (UnitLength.inches, _): return UnitLength.centimeters
        case (UnitLength.feet, _), (UnitLength.yards, _):
            return value.converted(to: UnitLength.meters).value < 1 ? UnitLength.centimeters : UnitLength.meters
        case (UnitLength.miles, _): return UnitLength.kilometers
        case (is UnitLength, _):
            let meters = value.converted(to: UnitLength.meters).value
            return meters < 0.3048 ? UnitLength.inches : meters < 1609.344 ? UnitLength.feet : UnitLength.miles
        case (UnitMass.ounces, _): return UnitMass.grams
        case (UnitMass.pounds, _):
            return value.converted(to: UnitMass.kilograms).value < 1 ? UnitMass.grams : UnitMass.kilograms
        case (is UnitMass, _):
            return value.converted(to: UnitMass.pounds).value < 1 ? UnitMass.ounces : UnitMass.pounds
        case (UnitVolume.quarts, _), (UnitVolume.gallons, _): return UnitVolume.liters
        case (is UnitVolume, .metric):
            return value.converted(to: UnitVolume.liters).value < 1 ? UnitVolume.milliliters : UnitVolume.liters
        case (is UnitVolume, _):
            let liters = value.converted(to: UnitVolume.liters).value
            return liters < 0.946 ? UnitVolume.fluidOunces : liters < 3.785 ? UnitVolume.quarts : UnitVolume.gallons
        case (is UnitTemperature, .metric): return UnitTemperature.celsius
        case (is UnitTemperature, _): return UnitTemperature.fahrenheit
        case (is UnitSpeed, .metric): return UnitSpeed.kilometersPerHour
        case (is UnitSpeed, _): return UnitSpeed.milesPerHour
        case (UnitArea.squareInches, _): return UnitArea.squareCentimeters
        case (UnitArea.squareFeet, _): return UnitArea.squareMeters
        case (UnitArea.acres, _): return UnitArea.hectares
        case (UnitArea.squareMiles, _): return UnitArea.squareKilometers
        case (UnitArea.squareCentimeters, _): return UnitArea.squareInches
        case (UnitArea.hectares, _): return UnitArea.acres
        case (UnitArea.squareKilometers, _): return UnitArea.squareMiles
        default: return system == .metric ? UnitArea.squareMeters : UnitArea.squareFeet
        }
    }

    private func format(_ measurement: Measurement<Dimension>, digits: Int? = nil, locale: Locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        let number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .decimal
        if let digits {
            number.maximumFractionDigits = digits
        } else {
            number.usesSignificantDigits = true
            number.maximumSignificantDigits = abs(measurement.value) >= 1000 ? 4 : 3
        }
        formatter.numberFormatter = number
        return formatter.string(from: measurement)
    }
}

extension Clipboard.Clip {
    /// The measurement this clip is, when it is only one.
    public var quantity: ClipQuantity? {
        kind == .text ? ClipQuantity.parse(preview) : nil
    }
}
