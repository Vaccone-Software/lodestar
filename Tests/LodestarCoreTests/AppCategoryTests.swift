import XCTest
@testable import LodestarCore

/// An app's kind: Lodestar's class where it knows the app, the app's own
/// declared category kept beside it, and the declared category trusted only
/// where it says something about the hand.
final class AppCategoryTests: XCTestCase {
    func testKnownAppsAreClassedByBundleWhateverTheyDeclare() {
        // Safari and Mail both declare productivity; the class tells them apart.
        let safari = AppCategory.of(bundleID: "com.apple.Safari", declared: "public.app-category.productivity")
        XCTAssertEqual(safari, AppCategory(kind: "browser", declared: "productivity"))
        XCTAssertEqual(AppCategory.of(bundleID: "com.apple.mail", declared: "public.app-category.productivity").kind, "mail")
        // Brave declares nothing at all.
        XCTAssertEqual(AppCategory.of(bundleID: "com.brave.Browser", declared: nil), AppCategory(kind: "browser", declared: nil))
        XCTAssertEqual(AppCategory.of(bundleID: "com.mitchellh.ghostty", declared: "public.app-category.developer-tools").kind, "terminal")
        XCTAssertEqual(AppCategory.of(bundleID: "com.jetbrains.intellij", declared: nil).kind, "code")
        XCTAssertEqual(AppCategory.of(bundleID: "com.google.Chrome.canary", declared: nil).kind, "browser")
    }

    func testTheDeclaredCategoryAnswersOnlyWhereItMeansSomething() {
        XCTAssertEqual(AppCategory.of(bundleID: "com.example.chat", declared: "public.app-category.social-networking").kind, "chat")
        XCTAssertEqual(AppCategory.of(bundleID: "jp.co.capcom.RE4US", declared: "public.app-category.action-games").kind, "game")
        XCTAssertEqual(AppCategory.of(bundleID: "com.example.tool", declared: "public.app-category.developer-tools"),
                       AppCategory(kind: "other", declared: "developer-tools"), "developer tools is not a claim about the hand")
        XCTAssertEqual(AppCategory.of(bundleID: nil, declared: nil), AppCategory(kind: "other", declared: nil))
    }

    func testEveryClassIsOneTheRecordNames() {
        for kind in Set(AppCategory.byBundle.values).union(AppCategory.byPrefix.map(\.1)) {
            XCTAssertTrue(AppCategory.kinds.contains(kind), kind)
        }
    }

    func testAClickPulseCarriesItsAppsKind() {
        var pulse = ClickPulse()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let brave = AppCategory(kind: "browser", declared: nil)
        _ = pulse.click(app: "Brave Browser", category: brave, role: "AXButton", trip: false, at: start)
        _ = pulse.scroll(app: "Ghostty", category: AppCategory(kind: "terminal", declared: "developer-tools"),
                         seconds: 1, at: start.addingTimeInterval(1))
        let events = pulse.flush(now: start.addingTimeInterval(2))
        XCTAssertEqual(events.map(\.app), ["brave browser", "ghostty"])
        XCTAssertEqual(events.map(\.category), ["browser", "terminal"])
        XCTAssertEqual(events.map(\.declaredCategory), [nil, "developer-tools"])
    }
}
