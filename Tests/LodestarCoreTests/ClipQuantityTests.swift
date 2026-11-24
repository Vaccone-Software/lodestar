import XCTest
@testable import LodestarCore

/// A measurement is read into your units, in the unit a person reaches for,
/// and one already in your units is left alone.
final class ClipQuantityTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    private func read(_ text: String, into system: ClipQuantity.System) -> String? {
        ClipQuantity.parse(text)?.note(into: system, locale: english)?.voice
    }

    func testIntoMetric() {
        XCTAssertEqual(read("72°F", into: .metric), "22°C")
        XCTAssertEqual(ClipQuantity.parse("72°F")?.note(into: .metric, locale: english)?.exact, "22.2°C",
                       "a rounded temperature carries its tenth beneath")
        XCTAssertEqual(read("6'2\"", into: .metric), "188 cm")
        XCTAssertEqual(read("6 ft 2 in", into: .metric), "188 cm")
        XCTAssertEqual(read("10 mi", into: .metric), "16.1 km")
        XCTAssertEqual(read("12 oz", into: .metric), "340 g")
        XCTAssertEqual(read("180 lb", into: .metric), "81.6 kg")
        XCTAssertEqual(read("1 cup", into: .metric), "240 mL")
        XCTAssertEqual(read("1 gal", into: .metric), "3.79 L")
        XCTAssertEqual(read("65 mph", into: .metric), "105 km/h")
    }

    func testIntoImperial() {
        XCTAssertEqual(read("5 km", into: .imperial), "3.11 mi")
        XCTAssertEqual(read("180 cm", into: .imperial), "5′ 11″", "a height is feet and inches")
        XCTAssertEqual(ClipQuantity.parse("180 cm")?.note(into: .imperial, locale: english)?.exact, "70.9 in")
        XCTAssertEqual(read("30 cm", into: .imperial), "11.8 in")
        XCTAssertEqual(read("100 m", into: .imperial), "328 ft")
        XCTAssertEqual(read("500 g", into: .imperial), "1.1 lb")
        XCTAssertEqual(read("500 mL", into: .imperial), "16.9 fl oz")
        XCTAssertEqual(read("-5 °C", into: .imperial), "23°F")
        XCTAssertEqual(read("2,5 kg", into: .imperial), "5.51 lb", "a decimal comma")
        XCTAssertEqual(read("1,500 m", into: .imperial), "4,921 ft", "a thousands comma")
    }

    func testYourOwnUnitsAreLeftAlone() {
        XCTAssertNil(ClipQuantity.parse("5 km")?.note(into: .metric, locale: english))
        XCTAssertNil(ClipQuantity.parse("72°F")?.note(into: .imperial, locale: english))
    }

    func testWhatIsNotAMeasurement() {
        XCTAssertNil(ClipQuantity.parse("10m"), "ten minutes in a log")
        XCTAssertNil(ClipQuantity.parse("5g"), "a network")
        XCTAssertNil(ClipQuantity.parse("-5 km"), "below zero only as a temperature")
        XCTAssertNil(ClipQuantity.parse("5 kilograms of flour"), "a sentence")
        XCTAssertNil(ClipQuantity.parse("km"))
        XCTAssertNotNil(ClipQuantity.parse("5 m"), "with its space, meters")
    }

    func testTheRegionDecidesUntilYouChoose() {
        XCTAssertEqual(ClipQuantity.System.regional(Locale(identifier: "en_US")), .imperial)
        XCTAssertEqual(ClipQuantity.System.regional(Locale(identifier: "en_GB")), .metric)
        XCTAssertEqual(ClipQuantity.System.regional(Locale(identifier: "de_DE")), .metric)
        XCTAssertEqual(ClipQuantity.System.chosen("", locale: Locale(identifier: "de_DE")), .metric)
        XCTAssertEqual(ClipQuantity.System.chosen("imperial", locale: Locale(identifier: "de_DE")), .imperial)
    }
}
