import Foundation
import StoicProcess

extension CodeNames {
    public static let sourceExtensions: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "rs", "kt",
                                                "java", "rb", "m", "mm", "h", "c", "cc", "cpp", "cs", "php", "scala",
                                                "dart", "lua", "ex", "exs", "zig", "vue", "svelte"]
    /// Declarations across the common languages: the name after the word
    /// that declares it.
    static let declaration = try! NSRegularExpression(pattern:
        #"\b(?:class|struct|enum|protocol|extension|actor|func|var|let|interface|type|def|fn|const|function|record|trait|impl|module|object)\s+([A-Za-z_][A-Za-z0-9_]{3,})"#)

    /// File names, declared symbols and branch names, most frequent symbols
    /// first, capped so a huge repository stays quick.
    public static func gather(_ root: URL) -> [String] {
        let files = git(root, ["ls-files", "-z"]).split(separator: "\0").map(String.init)
        var names: [String] = []
        var seen = Set<String>()
        func add(_ name: String) { if seen.insert(name).inserted { names.append(name) } }
        for path in files { add((path as NSString).lastPathComponent) }
        for branch in git(root, ["branch", "--format=%(refname:short)"]).split(separator: "\n") { add(String(branch)) }
        var counts: [String: Int] = [:]
        var bytes = 0
        for path in files where sourceExtensions.contains((path as NSString).pathExtension.lowercased()) {
            guard bytes < 30_000_000,
                  let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            bytes += text.utf8.count
            let ns = text as NSString
            for match in declaration.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                counts[ns.substring(with: match.range(at: 1)), default: 0] += 1
            }
        }
        for (name, _) in counts.sorted(by: { $0.value > $1.value }).prefix(15_000) { add(name) }
        return names
    }

    /// What git printed, or nothing when it failed or ran past the
    /// deadline. A repository with a stuck lock or a hook, or a vast one on
    /// a slow disk, is given up on rather than waited for: the names are a
    /// hint to dictation, and a draft never waits on them.
    static func git(_ root: URL, _ arguments: [String]) -> String {
        let command = Command("/usr/bin/git", ["-C", root.path] + arguments,
                              environment: Programs.environment, errors: .discard)
        guard case .success(let result) = Programs.runBlocking(command, timeout: gitDeadline, keepingLast: gitOutputLimit),
              result.succeeded, !result.outputTruncated else { return "" }
        return result.outputText
    }

    /// Long past `ls-files` on any repository a person works in.
    static let gitDeadline: Duration = .seconds(20)
    /// What git may print before the list is given up as too large to be
    /// worth reading: a 64 MiB file list is a repository far past the
    /// 15,000 names kept.
    static let gitOutputLimit = 64 * 1024 * 1024
}
