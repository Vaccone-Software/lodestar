import XCTest
@testable import lodestar

/// Every surface that can hold keys must let go of them when it hides.
///
/// `lode ?` is a question asked of a surface; the answer must not outlive
/// the asking. The draft learned this the hard way — it was the one
/// surface whose `hide()` did not drop its keys, so a draft closed with
/// them up came back with them up. A source scan rather than a scenario
/// per surface, because the point is that the *next* keyed surface
/// cannot forget either.
final class KeysDismissDriftTests: XCTestCase {
    /// What counts as letting go, in any of the spellings the surfaces
    /// use: `BarKeys.hide()`, or clearing a view the surface holds itself.
    private let releases = ["keys.hide()", "keys?.removeFromSuperview()",
                            "keysView = nil", "keys = nil"]

    func testEverySurfaceWithKeysDropsThemWhenItHides() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/lodestar")
        let files = try FileManager.default.contentsOfDirectory(at: root,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var scanned: [String] = []
        var offenders: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // A surface that can hold keys is one that owns the state.
            guard source.contains("BarKeys()") || source.contains("keysShown") else { continue }
            // An implementation, not a protocol's requirement: the seam
            // file declares `hide()` without a body and has nothing to
            // drop.
            guard source.contains("func hide() {") else { continue }
            let name = file.lastPathComponent
            scanned.append(name)
            guard let start = source.range(of: "func hide() {") else { continue }
            let body = source[start.upperBound...].prefix(400)
            if !releases.contains(where: { body.contains($0) }) { offenders.append(name) }
        }
        XCTAssertFalse(scanned.isEmpty, "the scan found no keyed surfaces, so it proves nothing")
        XCTAssertEqual(offenders, [],
                       "these hide without dropping their keys, so they come back showing them")
    }
}
