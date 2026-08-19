import Foundation

/// Structured, rotating file log at ~/.local/share/lodestar/lodestar.log,
/// mirrored to stdout. logfmt shape — `HH:mm:ss.SSS INFO summon target=Slack
/// chose=8688` — so humans tail it and tools parse it. Rotates at 5MB,
/// keeping two predecessors (.1, .2): bounded at ~15MB, history preserved.
public enum Log {
    public static let directory = Paths.data
    public static let file = directory.appendingPathComponent("lodestar.log")

    private static let maxBytes = 5_000_000
    private static let keptRotations = 2

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Everything that touches `handle` or `bytesWritten` runs here.
    ///
    /// Most of the app logs on main, but the updater does not: its worker
    /// queue and the URLSession completion queue both call straight into
    /// `write`. Unsynchronized, two threads could open two handles for the
    /// same file, lose bytes off the non-atomic counter (so the 15MB bound
    /// stopped holding), or — with one thread inside `rotate` — write to a
    /// handle the other had just closed, which raises
    /// `NSFileHandleOperationException` and takes the process with it.
    ///
    /// Synchronous, not async: a log line must still be on disk when a
    /// crash follows it, which is exactly when the log matters most.
    private static let io = DispatchQueue(label: "lodestar.log")
    private static var handle: FileHandle?
    private static var bytesWritten: UInt64 = 0

    /// Tests exercise the same classes; their log lines must never land in
    /// the user's live file. Under XCTest, stdout only.
    /// CLI commands print reports, not log streams.
    public static var stdoutEnabled = true

    public static var fileEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] == nil && env["SWIFT_TESTING_ENABLED"] == nil
    }()

    public static func info(_ event: String, _ fields: KeyValuePairs<String, Any> = [:]) {
        write("INFO", event, fields)
    }

    public static func error(_ event: String, _ fields: KeyValuePairs<String, Any> = [:]) {
        write("ERR ", event, fields)
    }

    private static func write(_ level: String, _ event: String, _ fields: KeyValuePairs<String, Any>) {
        var line = "\(formatter.string(from: Date())) \(level) \(event)"
        for (key, value) in fields {
            line += " \(key)=\(format(value))"
        }
        line += "\n"
        if stdoutEnabled { print(line, terminator: "") }
        guard fileEnabled, let data = line.data(using: .utf8) else { return }
        io.sync {
            ensureHandle()
            // `write(contentsOf:)` throws where the old `write(_:)` raised
            // an Objective-C exception Swift cannot catch — a full disk or
            // a closed descriptor used to abort the process outright.
            do {
                try handle?.write(contentsOf: data)
            } catch {
                return
            }
            bytesWritten += UInt64(data.count)
            if bytesWritten > maxBytes {
                rotate()
            }
        }
    }

    private static func format(_ value: Any) -> String {
        let text: String
        switch value {
        case let array as [Any]:
            text = "[" + array.map { "\($0)" }.joined(separator: ",") + "]"
        default:
            text = "\(value)"
        }
        if text.contains(" ") || text.contains("=") || text.contains("\"") {
            return "\"\(text.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return text.isEmpty ? "\"\"" : text
    }

    /// Callers must already be on `io`.
    private static func ensureHandle() {
        dispatchPrecondition(condition: .onQueue(io))
        guard handle == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        handle?.seekToEndOfFile()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64
        bytesWritten = size ?? 0
    }

    /// lodestar.log -> .1 -> .2, oldest dropped. Callers must already be
    /// on `io` — closing the handle while another thread is mid-write is
    /// precisely the race this queue exists to prevent.
    private static func rotate() {
        dispatchPrecondition(condition: .onQueue(io))
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let oldest = directory.appendingPathComponent("lodestar.log.\(keptRotations)")
        try? fm.removeItem(at: oldest)
        for index in stride(from: keptRotations - 1, through: 1, by: -1) {
            let from = directory.appendingPathComponent("lodestar.log.\(index)")
            let to = directory.appendingPathComponent("lodestar.log.\(index + 1)")
            try? fm.moveItem(at: from, to: to)
        }
        try? fm.moveItem(at: file, to: directory.appendingPathComponent("lodestar.log.1"))
        bytesWritten = 0
        ensureHandle()
    }
}
