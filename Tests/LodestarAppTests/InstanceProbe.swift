import Foundation
import XCTest

/// A `probe copy` or `probe stranger` run for a test: a real process that
/// says what it does a line at a time, each with the moment it was read, so
/// that the order of two processes' doings can be asserted. The probe is built
/// beside the test bundles (`swift build --build-tests`), and every process
/// started here is ended when the test is, so none outlives it.
///
/// A test never signals a process it did not start here, and never starts the
/// app: the probe only ever touches the files it is handed.
final class InstanceProbe {
    private let process = Process()
    private let lock = NSLock()
    private var stored: [(line: String, at: Date)] = []
    private var partial = ""
    private let exited = DispatchSemaphore(value: 0)
    private(set) var arguments: [String]

    /// Where the probe binary is: beside the test bundle.
    static func executable(for testClass: AnyClass) -> URL {
        Bundle(for: testClass).bundleURL.deletingLastPathComponent().appendingPathComponent("probe")
    }

    /// Starts `probe <arguments>`. Throws when the probe is not built.
    init(_ arguments: [String], from testClass: AnyClass) throws {
        self.arguments = arguments
        let tool = Self.executable(for: testClass)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            XCTFail("the probe is not built beside the tests (\(tool.path)): swift build --build-tests builds it")
            throw CocoaError(.fileNoSuchFile)
        }
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
    }

    deinit { end() }

    private func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        partial += text
        while let newline = partial.firstIndex(of: "\n") {
            stored.append((String(partial[..<newline]), Date()))
            partial.removeSubrange(...newline)
        }
    }

    var pid: Int32 { process.processIdentifier }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored.map(\.line)
    }

    /// When the first line starting with `prefix` was read, if one was.
    func moment(of prefix: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return stored.first { $0.line.hasPrefix(prefix) }?.at
    }

    /// Waits for a line starting with `prefix`; its text, or nil on timeout.
    @discardableResult
    func wait(for prefix: String, timeout: TimeInterval = 20) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let found = stored.first { $0.line.hasPrefix(prefix) }?.line
            lock.unlock()
            if let found { return found }
            usleep(10_000)
        }
        return nil
    }

    /// Waits for the process to end; its status, or nil on timeout. A status
    /// of 128 + n is a signal n.
    func waitForExit(timeout: TimeInterval = 20) -> Int32? {
        guard exited.wait(timeout: .now() + timeout) == .success else { return nil }
        exited.signal()
        return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    }

    var isRunning: Bool { process.isRunning }

    /// A crash: no chance to say anything, nothing released but by the kernel.
    func crash() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit()
    }

    func end() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

extension XCTestCase {
    /// A folder of the test's own, removed when it ends.
    func instanceFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
