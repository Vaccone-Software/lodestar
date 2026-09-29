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

    /// Everything that touches the appender runs here.
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
    private static let appender = AppendingFile(url: file, maxBytes: UInt64(maxBytes), keptRotations: keptRotations)

    /// Tests exercise the same classes; their log lines must never land in
    /// the user's live file. Under XCTest, stdout only.
    /// CLI commands print reports, not log streams.
    public static var stdoutEnabled = true

    /// Every line as written — for a test that reads what the app said,
    /// the editor's promise that no line carries the writer's words.
    public static var listener: ((String) -> Void)?

    /// Off under any test runner. `swift test` says so in the environment;
    /// `xcrun xctest` run directly (scripts/test.sh's shards) does not, so
    /// the loaded XCTest framework is asked too — the app never links it.
    public static var fileEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] == nil && env["SWIFT_TESTING_ENABLED"] == nil
            && NSClassFromString("XCTestCase") == nil
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
        listener?(line)
        if stdoutEnabled { print(line, terminator: "") }
        guard fileEnabled, let data = line.data(using: .utf8) else { return }
        io.sync { appender.append(data) }
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
}

/// A text file more than one process appends to: the app, a successor
/// taking over from it at an update, the CLI. It was a `FileHandle` opened
/// once and sought to the end once, so each writer kept its own idea of
/// where the end was and wrote over the other's bytes — the live log held
/// lines like `NFO draft open=speak` and `24) did not exit in 5s`, and a
/// writer whose file another had rotated away went on writing into `.1`.
///
/// Opened with `O_APPEND`, every write lands at the end as it is at that
/// moment, whoever else is writing. The path is followed: when the file on
/// disk is no longer the one open, it is opened afresh. A write that fails
/// (a full disk) drops the line and never raises. The size that decides
/// rotation is the file's, not this writer's count. Not thread-safe:
/// callers serialize.
public final class AppendingFile {
    public let url: URL
    private let maxBytes: UInt64
    private let keptRotations: Int
    private var descriptor: Int32 = -1
    private var inode: ino_t = 0

    public init(url: URL, maxBytes: UInt64, keptRotations: Int) {
        self.url = url
        self.maxBytes = maxBytes
        self.keptRotations = keptRotations
    }

    deinit { closeDescriptor() }

    public func append(_ data: Data) {
        openIfNeeded()
        guard descriptor >= 0, !data.isEmpty else { return }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written >= 0 else {
            closeDescriptor()
            return
        }
        var status = stat()
        if fstat(descriptor, &status) == 0, UInt64(status.st_size) > maxBytes { rotate() }
    }

    private func openIfNeeded() {
        if descriptor >= 0 {
            var onDisk = stat()
            if stat(url.path, &onDisk) == 0, onDisk.st_ino == inode { return }
            closeDescriptor()
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        var status = stat()
        inode = fstat(descriptor, &status) == 0 ? status.st_ino : 0
    }

    private func closeDescriptor() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    /// `name` → `name.1` → … → `name.<kept>`, the oldest dropped. The next
    /// append opens a fresh file at the path.
    private func rotate() {
        closeDescriptor()
        let fm = FileManager.default
        let base = url.path
        try? fm.removeItem(atPath: "\(base).\(keptRotations)")
        for index in stride(from: keptRotations - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(base).\(index)", toPath: "\(base).\(index + 1)")
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
    }
}
