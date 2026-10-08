import Foundation

/// Whether this process is a test run, and the home it keeps instead of
/// the person's.
///
/// Every store defaults to the real `~/.local/share/lodestar` and every
/// sound, post and focus change reaches the real Mac, and the tests were
/// kept off them one argument at a time. One forgotten argument would
/// have written into a person's history. Under a test run the defaults
/// themselves are inert: `Paths` resolves into `home`, and the app's
/// `SystemEvents` posts nothing, takes no focus and uses a pasteboard of
/// its own.
public enum TestRun {
    /// `swift test` says so in the environment; `xcrun xctest` run
    /// directly (scripts/test.sh's shards) does not, so the loaded XCTest
    /// framework is asked too. The app never links it.
    public static let active: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["SWIFT_TESTING_ENABLED"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// A home of this run's own, made on first use, under the temporary
    /// directory so the system clears it.
    public static let home: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-test-home-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
