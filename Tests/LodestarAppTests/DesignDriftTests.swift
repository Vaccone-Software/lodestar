import AppKit
import XCTest
@testable import lodestar

/// The design language never drifts: a radius, a type size or a symbol
/// configuration reaches a surface only through the theme, the way the
/// accent already does. A literal in a surface fails the build with the
/// file named, so the φ table and the type scale stay the only source.
final class DesignDriftTests: XCTestCase {
    /// The theme's homes: the values live here and nowhere else.
    private static let homes: Set<String> = ["Glass.swift", "ModePill.swift"]

    private func surfaces() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !Self.homes.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 20, "the sources were found")
        return files
    }

    private func offenders(_ pattern: String, in files: [URL]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            for match in matches {
                let line = (text as NSString).substring(with: match.range)
                found.append("\(file.lastPathComponent): \(line)")
            }
        }
        return found
    }

    func testNoSurfaceDrawsACornerRadiusOfItsOwn() throws {
        let hits = try offenders(#"cornerRadius\s*[:=]\s*[0-9]"#, in: surfaces())
        XCTAssertEqual(hits, [], "a radius comes from the theme's table, never a literal")
    }

    func testNoSurfaceSetsATypeSizeOfItsOwn() throws {
        let hits = try offenders(#"ofSize:\s*[0-9]"#, in: surfaces())
        XCTAssertEqual(hits, [], "a size comes from the type scale, never a literal")
    }

    func testNoSurfaceConfiguresASymbolOfItsOwn() throws {
        let hits = try offenders(#"SymbolConfiguration\(pointSize:\s*[0-9]|\.init\(pointSize:\s*[0-9]"#, in: surfaces())
        XCTAssertEqual(hits, [], "a symbol wears the theme's configuration, never its own")
    }

    func testTheThemeHoldsWhatTheGuardExpects() {
        XCTAssertEqual(BarTheme.glassChipRadius, 4.5)
        XCTAssertEqual(BarTheme.typedFont.pointSize, 17)
        XCTAssertGreaterThan(BarTheme.typedFont.pointSize, BarTheme.bodyFont.pointSize)
        XCTAssertEqual(BarTheme.symbol.value(forKey: "pointSize") as? CGFloat, BarTheme.Scale.meta)
    }
}
