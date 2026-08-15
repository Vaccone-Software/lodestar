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
        guard fileEnabled else { return }
        ensureHandle()
        if let data = line.data(using: .utf8) {
            handle?.write(data)
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

    private static func ensureHandle() {
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

    /// lodestar.log -> .1 -> .2, oldest dropped.
    private static func rotate() {
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
