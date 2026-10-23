import Foundation

/// A place on the Earth, in degrees: latitude north-positive, longitude
/// east-positive.
public struct Coordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// When the sun rises and sets on a day, by the NOAA solar calculator's
/// algorithm (Meeus, "Astronomical Algorithms", the low-precision
/// equations): the sun's declination and the equation of time from the
/// Julian century, the hour angle at which its upper limb meets a horizon
/// lifted by refraction. Good to a minute or two away from the poles, which
/// is far finer than a screen that eases down over an hour needs.
///
/// Pure: the date, the place and the time zone are all passed in, so a test
/// states the answer for a day it picks and nothing reads the clock.
public enum Sun {
    public enum Day: Equatable, Sendable {
        case rises(sunrise: Date, sunset: Date)
        /// The sun stays up all day (the midnight sun).
        case polarDay
        /// The sun does not come up.
        case polarNight
    }

    /// The zenith angle of sunrise and sunset: ninety degrees, plus the
    /// sun's radius and the refraction of the atmosphere at the horizon.
    static let horizon = 90.833

    /// The sunrise and sunset of the local day that `date` falls in, by the
    /// calendar of `zone`. Each is the instant of the day's own event, so a
    /// sunset after midnight (a far-western place in a wide zone) is still
    /// that day's.
    public static func day(containing date: Date, at place: Coordinate, in zone: TimeZone) -> Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date

        let julianDay = noon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let century = (julianDay - 2_451_545) / 36_525
        let (declination, equationOfTime) = solarPosition(century: century)

        let latitude = rad(place.latitude)
        let cosHourAngle = cos(rad(horizon)) / (cos(latitude) * cos(declination)) - tan(latitude) * tan(declination)
        if cosHourAngle > 1 { return .polarNight }
        if cosHourAngle < -1 { return .polarDay }
        let hourAngle = deg(acos(cosHourAngle))

        // Solar noon in minutes after midnight UTC, which for a place far
        // from Greenwich falls on the neighbouring UTC day: take the one
        // nearest the local noon.
        let noonMinutes = 720 - 4 * place.longitude - equationOfTime
        let utcMidnight = (noon.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        let solarNoon = [-1.0, 0, 1]
            .map { utcMidnight + ($0 * 1_440 + noonMinutes) * 60 }
            .min { abs($0 - noon.timeIntervalSince1970) < abs($1 - noon.timeIntervalSince1970) }!
        let half = hourAngle * 4 * 60
        return .rises(sunrise: Date(timeIntervalSince1970: solarNoon - half),
                      sunset: Date(timeIntervalSince1970: solarNoon + half))
    }

    /// The sun's declination (radians) and the equation of time (minutes)
    /// at a Julian century from J2000.
    static func solarPosition(century t: Double) -> (declination: Double, equationOfTime: Double) {
        let meanLongitude = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = rad(meanAnomaly)
        let centre = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t) + sin(3 * m) * 0.000289
        let trueLongitude = meanLongitude + centre
        let apparent = trueLongitude - 0.00569 - 0.00478 * sin(rad(125.04 - 1_934.136 * t))
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = rad(meanObliquity + 0.00256 * cos(rad(125.04 - 1_934.136 * t)))
        let declination = asin(sin(obliquity) * sin(rad(apparent)))

        let y = tan(obliquity / 2) * tan(obliquity / 2)
        let l0 = rad(meanLongitude)
        let equation = y * sin(2 * l0) - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0) - 0.5 * y * y * sin(4 * l0)
            - 1.25 * eccentricity * eccentricity * sin(2 * m)
        return (declination, 4 * deg(equation))
    }

    private static func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func deg(_ radians: Double) -> Double { radians * 180 / .pi }
}

/// Where the Mac probably is, from nothing but its time zone, so that no
/// permission is asked for the one thing the schedule needs: roughly which
/// way the sun is. The tz database lists a coordinate for the principal
/// city of each zone (`zone1970.tab`, and `zone.tab`, which also lists the
/// zones that were merged into another after 1970); a zone neither names
/// falls back to the longitude its offset from UTC implies and a mid
/// latitude. A degree of latitude moves a sunset by minutes and a degree of
/// longitude by four, so a city in the zone is as good as the person's own
/// street for a curve that takes an hour to move.
public enum ZoneCoordinates {
    /// The coordinates a tz table lists, by zone identifier. Rows are
    /// tab-separated: countries, ±DDMM±DDDMM (or with seconds), the zone,
    /// and comments; a comment line starts with `#`.
    public static func parse(_ table: String) -> [String: Coordinate] {
        var found: [String: Coordinate] = [:]
        for line in table.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, let place = coordinate(iso6709: String(columns[1])) else { continue }
            found[String(columns[2])] = place
        }
        return found
    }

    /// ISO 6709 as the tz tables write it: sign, degrees and minutes (and
    /// seconds), for latitude then longitude: `+4042-07400`, `+404251-0740023`.
    public static func coordinate(iso6709 text: String) -> Coordinate? {
        let characters = Array(text)
        guard let first = characters.first, first == "+" || first == "-",
              let split = characters.indices.dropFirst().first(where: { characters[$0] == "+" || characters[$0] == "-" })
        else { return nil }
        func parts(_ slice: ArraySlice<Character>, degreeDigits: Int) -> Double? {
            let sign: Double = slice.first == "-" ? -1 : 1
            let digits = slice.dropFirst()
            guard digits.allSatisfy(\.isNumber),
                  digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4 else { return nil }
            let numbers = digits.map { Double(String($0))! }
            func number(_ range: Range<Int>) -> Double { numbers[range].reduce(0) { $0 * 10 + $1 } }
            let degrees = number(0..<degreeDigits)
            let minutes = number(degreeDigits..<(degreeDigits + 2))
            let seconds = digits.count == degreeDigits + 4 ? number((degreeDigits + 2)..<(degreeDigits + 4)) : 0
            return sign * (degrees + minutes / 60 + seconds / 3_600)
        }
        guard let latitude = parts(characters[0..<split], degreeDigits: 2),
              let longitude = parts(characters[split...], degreeDigits: 3),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// The zone's listed city, or the offset's meridian. `standardOffset` is
    /// the zone's offset from UTC without daylight saving, in seconds, and
    /// `southern` says the zone puts its clocks forward in the northern
    /// winter, which is the one thing a zone says about its hemisphere.
    public static func estimate(identifier: String, tables: [String], standardOffset: TimeInterval,
                                southern: Bool) -> Coordinate {
        for table in tables {
            if let place = parse(table)[identifier] { return place }
        }
        return fallback(standardOffset: standardOffset, southern: southern)
    }

    /// Fifteen degrees to the hour, at the latitude where most of any
    /// hemisphere's people are.
    public static func fallback(standardOffset: TimeInterval, southern: Bool) -> Coordinate {
        let longitude = min(180, max(-180, standardOffset / 3_600 * 15))
        return Coordinate(latitude: southern ? -35 : 40, longitude: longitude)
    }
}
