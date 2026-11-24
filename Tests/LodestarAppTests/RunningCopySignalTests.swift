import XCTest

/// The command line tells a running Lodestar to reload (SIGUSR2, whose default
/// action ends a process that does not catch it). It once found that process
/// by the pid file alone, so a pid left by a crash and given since to another
/// of the person's processes was sent the signal. Whoever signals a running
/// copy now finds it through `SingleInstance.runningCopy`, which never answers
/// a process that only has the number.
final class RunningCopySignalTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testNothingOnTheCommandLineSignalsAPidReadFromThePidFile() throws {
        for path in ["Sources/lodestar/ConfigDoctor.swift", "Sources/lodestar/main.swift"] {
            let text = try source(path)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("kill(pid, SIGUSR2)") {
                // The pid a signal goes to comes from `runningLodestar()` within
                // the few lines above it, never from the file's contents.
                let above = lines[max(0, index - 6)..<index].joined(separator: "\n")
                XCTAssertTrue(above.contains("runningLodestar()"),
                              "\(path):\(index + 1) signals a pid that did not come from runningLodestar()")
                XCTAssertFalse(above.contains("contentsOf: Paths.pidFile") || above.contains("contentsOf: pidPath"),
                               "\(path):\(index + 1) signals a pid read from the pid file")
            }
        }
    }
}
