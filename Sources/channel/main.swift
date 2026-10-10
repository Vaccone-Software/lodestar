import Foundation
import LodestarCore

// The stable channel from the command line: the same Promotion the app's
// updater runs, over the same releases list, so the Homebrew job and a
// person at a terminal see exactly what the stable Macs see. Built on
// LodestarCore alone, so CI compiles it in seconds, without MLX.
//
//   gh api 'repos/Vaccone-Software/lodestar/releases?per_page=100' | channel
//       prints the stable tag (exit 1 when there is none)
//   … | channel --status
//       the newest build, stable, and every line on its way
//   … | channel --now 2026-10-20T00:00:00Z [--status]
//       the same, as of another moment

var arguments = Array(CommandLine.arguments.dropFirst())
var status = false
var now = Date()
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--status":
        status = true
    case "--now":
        guard let value = arguments.first, let date = ISO8601DateFormatter().date(from: value) else {
            FileHandle.standardError.write(Data("✕ --now wants an ISO 8601 moment, like 2026-10-20T00:00:00Z\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        now = date
    default:
        FileHandle.standardError.write(Data("usage: channel [--status] [--now <iso8601>] < releases.json\n".utf8))
        exit(2)
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let builds = Promotion.parseFeed(input) else {
    FileHandle.standardError.write(Data("✕ not a releases list\n".utf8))
    exit(1)
}
let stable = Promotion.stable(builds, now: now)

guard status else {
    guard let stable else { exit(1) }
    print(stable.tag)
    exit(0)
}

let iso = ISO8601DateFormatter()
func span(_ seconds: TimeInterval) -> String {
    let hours = Int((seconds / 3600).rounded(.up))
    return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h"
}
let newest = builds.filter { !$0.draft && $0.hasZip && $0.published <= now }
    .max { Updater.isNewer($1.version, than: $0.version) }
print("preview  \(newest?.tag ?? "none")")
print("stable   \(stable?.tag ?? "none")")
for line in Promotion.pending(builds, now: now) {
    let name = line.line.map(String.init).joined(separator: ".")
    let kind = line.isPatch ? "patch" : "minor"
    print("pending  \(name) (\(kind), since \(iso.string(from: line.since))): \(line.build.tag) in \(span(line.promotes.timeIntervalSince(now)))")
}
for held in builds where held.isHeld {
    print("held     \(held.tag)")
}
