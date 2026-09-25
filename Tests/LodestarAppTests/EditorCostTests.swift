import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the editor costs while nothing happens: reads of the focused
/// field per minute, and what one read costs, on the real accessibility
/// path with the real notifications. On demand — it watches whatever is
/// frontmost for a minute:
///
///     LODESTAR_EDITOR_MEASURE=60 swift test --filter EditorCostTests
final class EditorCostTests: XCTestCase {
    private final class Counting: EditorFieldSource, @unchecked Sendable {
        let real = AXFieldSource()
        let lock = NSLock()
        var reads = 0
        var seconds: TimeInterval = 0
        func focusedField(frontmost: pid_t?) -> EditorField? {
            let started = Date()
            let field = real.focusedField(frontmost: frontmost)
            lock.withLock { reads += 1; seconds += Date().timeIntervalSince(started) }
            return field
        }
        func rects(for ranges: [NSRange], in field: EditorField) -> [CGRect?] { real.rects(for: ranges, in: field) }
        func replace(_ range: NSRange, expected: String, with text: String, in field: EditorField) -> Bool { false }
    }

    func testReadsPerIdleMinute() throws {
        guard let window = ProcessInfo.processInfo.environment["LODESTAR_EDITOR_MEASURE"].flatMap(Double.init) else {
            throw XCTSkip("LODESTAR_EDITOR_MEASURE=<seconds> measures the idle cost")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("the launching terminal needs Accessibility") }
        let source = Counting()
        let controller = EditorController(source: source, proofreader: FakeProofreader(),
                                          drawing: FakeMarksDrawing(), hover: nil, modelReady: { _ in false })
        controller.apply(enabled: true, engine: .spelling, language: "en_US", vocabulary: [], skipApps: [])
        let cpuBefore = ProcessInfo.processInfo.systemUptime
        _ = cpuBefore
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let before = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        RunLoop.main.run(until: Date().addingTimeInterval(window))
        getrusage(RUSAGE_SELF, &usage)
        let after = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        controller.apply(enabled: false, engine: .spelling, language: "en_US", vocabulary: [], skipApps: [])
        let (reads, spent) = source.lock.withLock { (source.reads, source.seconds) }
        let perMinute = Double(reads) / window * 60
        print(String(format: "editor cost · %d reads in %.0f s (%.0f a minute; polling every 0.2 s was 300) · %.2f ms a read · process CPU %.2f s",
                     reads, window, perMinute, spent / Double(max(1, reads)) * 1000, after - before))
        XCTAssertLessThan(perMinute, 90, "idle, the slow beat and nothing else")
    }
}

final class EditorWatchProbeTests: XCTestCase {
    func testWhatTheFrontmostAppAnnounces() throws {
        guard let window = ProcessInfo.processInfo.environment["LODESTAR_EDITOR_MEASURE"].flatMap(Double.init) else {
            throw XCTSkip("LODESTAR_EDITOR_MEASURE=<seconds>")
        }
        let front = NSWorkspace.shared.frontmostApplication
        print("frontmost: \(front?.localizedName ?? "?") pid \(front?.processIdentifier ?? 0)")
        var counts: [String: Int] = [:]
        let pid = try XCTUnwrap(front?.processIdentifier)
        let observer = try XCTUnwrap(AppObserver(pid: pid) { name, _ in counts[name, default: 0] += 1 })
        let app = AXUIElementCreateApplication(pid)
        for name in EditorWatch.notifications { print("watch \(name): \(observer.watch(name, on: app))") }
        let started = Date()
        let field = EditorAX.queue.sync { EditorAX.focusedField() }
        print(String(format: "a read: %.2f ms → %@", Date().timeIntervalSince(started) * 1000,
                     field.map { "\($0.appName) field" } ?? "no readable field"))
        let system = AXUIElementCreateSystemWide()
        let t = Date()
        let focused = AX.element(system, kAXFocusedUIElementAttribute as String)
        print(String(format: "focused element: %.2f ms, role %@", Date().timeIntervalSince(t) * 1000,
                     focused.flatMap { AX.string($0, kAXRoleAttribute as String) } ?? "none"))
        RunLoop.main.run(until: Date().addingTimeInterval(window))
        print("notifications in \(Int(window)) s: \(counts)")
        observer.invalidate()
    }
}
