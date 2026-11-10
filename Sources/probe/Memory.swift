import Darwin
import Foundation
import LodestarCore
import StoicSealed
import Stoic
import StoicTime

/// `probe memory-seed`, `memory-rollup` and `memory-coach`: what the three
/// launch-time readers of the logbook cost in memory, measured in a process of this
/// command's own.
///
/// The peak a process has reached is one number for the process's life, and
/// a test process has run a hundred other tests before it gets to ask. So
/// this is a process of its own, and the synthetic logbook it reads is
/// written by another (`memory-prepare`, a child of this one: sealed under a
/// key that lives in memory and is handed over in the folder both remove),
/// because writing a logbook leaves the heap holding what it freed and that
/// would hide what the reader then allocates. It takes the footprint, starts
/// the peak over, runs the reader, and says both: `baseline` and `peak`, in
/// bytes, and what is left after.
///
///   probe memory-seed   --events 220000   the prewarmer's boot seed: ninety days of focus
///   probe memory-rollup --events 350000   the monthly roll: thirteen months, both logs, rotated
///   probe memory-coach  --events 220000   the coach's refresh: ninety days of whole events, held
///   --legacy                              the whole-read path both used to take, to compare
///
/// The last line of standard output is `RESULT {json}`; progress goes to
/// standard error.
func runMemory(_ args: inout [String], rollup: Bool, coach: Bool = false) {
    var events = rollup ? 350_000 : 220_000
    var legacy = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--events": index += 1; events = Int(args[index]) ?? events
        case "--legacy": legacy = true
        default: break
        }
        index += 1
    }
    let started = ContinuousClock.now
    func say(_ text: String) {
        let (current, peak) = MemoryProbe.footprint()
        FileHandle.standardError.write(Data(String(
            format: "%6.1fs footprint %d MB interval-peak %d MB  %@\n", started.secondsElapsed,
            current >> 20, peak >> 20, text).utf8))
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lodestar-memprobe-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // `exit` runs no `defer`, so a failure takes the folder with it first.
    func fail(_ why: String) -> Never {
        fputs("probe: \(why)\n", stderr)
        try? FileManager.default.removeItem(at: directory)
        exit(1)
    }

    // A year and a month for the roll, which has months to roll; eighty days
    // for the seed, which reads a ninety-day window. Both rotated, as the app
    // leaves a ring at launch: closed months in shards, the open month live.
    let child = Process()
    child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["memory-prepare", "--dir", directory.path, "--events", "\(events)",
                       "--span-days", rollup ? "395" : "80", "--rotate"] + (rollup ? ["--health"] : [])
    do { try child.run() } catch { fail("could not start the writer: \(error)") }
    child.waitUntilExit()
    guard child.terminationStatus == 0, let key = MemoryProbe.readKey(in: directory) else {
        fail("the writer did not finish")
    }
    let vault = Vault(custody: InMemoryKeyCustody(key), directory: directory)
    let store = ObservationStore(file: directory.appendingPathComponent("observations.json"), vault: vault)
    let now = Moment.now.date
    say("written \(events) events, by the child")

    MemoryProbe.letGo()
    let baseline = MemoryProbe.footprint().current
    MemoryProbe.restartPeak()
    say("baseline")

    var detail = ""
    var held: [ObservationEvent] = []
    if coach {
        // CoachController's refresh: the last ninety days of the ring as events, all of them held.
        held = store.log.snapshot(days: EventLog.advisorWindowDays)
        detail = "\"held\":\(held.count)"
    } else if rollup {
        let ring = vault.ring(.logbook)
        let file = store.rollupFile
        if legacy {
            let outcome = Rollup.roll(events: store.allEvents(), file: file, ring: ring, now: now)
            detail = "\"archived\":\(outcome.added.count)"
        } else {
            let outcome = store.roll(now: now)
            detail = "\"archived\":\(outcome.added.count)"
        }
    } else {
        if legacy {
            let all = store.log.snapshot(days: EventLog.advisorWindowDays)
            let tuning = NextApp.tune(events: all)
            let scores = NextApp.evaluate(events: all, tuning: tuning)
            var seeded = NextApp(tuning: tuning)
            for event in all.filter({ $0.kind == .focus }).sorted(by: { $0.t < $1.t }) {
                if let app = event.app { seeded.observe(app) }
            }
            detail = "\"switches\":\(scores.first?.switches ?? 0),\"history\":\(seeded.history.count)"
        } else {
            let learned = NextApp.seed(from: store.log, retune: true, current: NextApp.Tuning())
            detail = "\"switches\":\(learned.scores.first?.switches ?? 0),\"history\":\(learned.model.history.count)"
        }
    }
    let (after, peak) = MemoryProbe.footprint()
    say("done \(held.count)")
    print("RESULT {\"mode\":\"\(coach ? "coach" : rollup ? "rollup" : "seed")\",\"path\":\"\(coach ? "whole" : legacy ? "legacy" : "stream")\","
          + "\"events\":\(events),\"baseline\":\(baseline),\"peak\":\(max(peak, baseline)),\"after\":\(after),"
          + "\"stride\":\(MemoryLayout<ObservationEvent>.stride),\(detail)}")
}

/// `probe memory-prepare --dir D --events N --span-days S [--rotate] [--health]`: the
/// writer `memory-seed` and `memory-rollup` start. Not for a person.
func runMemoryPrepare(_ args: inout [String]) {
    var directory: URL?
    var events = 0
    var spanDays = 80.0
    var rotate = false
    var health = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--health": health = true
        case "--dir": index += 1; directory = URL(fileURLWithPath: args[index], isDirectory: true)
        case "--events": index += 1; events = Int(args[index]) ?? events
        case "--span-days": index += 1; spanDays = Double(args[index]) ?? spanDays
        case "--rotate": rotate = true
        default: break
        }
        index += 1
    }
    guard let directory else { fputs("probe: memory-prepare needs --dir\n", stderr); exit(2) }
    let custody = InMemoryKeyCustody()
    let vault = Vault(custody: custody, directory: directory)
    let store = ObservationStore(file: directory.appendingPathComponent("observations.json"), vault: vault)
    let now = Moment.now.date
    MemoryProbe.write(events: events, spanDays: spanDays, now: now, store: store, health: health)
    if rotate {
        store.log.compact(now: now)
        store.healthLog.compact(now: now)
    }
    store.log.close()
    store.healthLog.close()
    MemoryProbe.writeKey(custody, in: directory)
}

enum MemoryProbe {
    /// The synthetic key, handed from the writer to the reader as the one
    /// file of the scratch folder that is not the logbook's.
    static func writeKey(_ custody: InMemoryKeyCustody, in directory: URL) {
        var items: [String: String] = [:]
        for name in custody.names {
            items[name] = (custody.contents(of: name) ?? []).map { String(format: "%02x", $0) }.joined()
        }
        try? JSONEncoder().encode(items).write(to: directory.appendingPathComponent("memprobe-key.json"))
    }

    static func readKey(in directory: URL) -> [String: [UInt8]]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("memprobe-key.json")),
              let items = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return items.mapValues { hex in
            stride(from: 0, to: hex.count, by: 2).compactMap { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
            }
        }
    }

    /// The footprint now, and the highest it has been since `restartPeak`
    /// (since launch when the system will not restart it), in bytes: the
    /// number Activity Monitor calls Memory, not the resident size.
    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return (0, 0) }
        return (info.ri_phys_footprint, restarted ? info.ri_interval_max_phys_footprint : info.ri_lifetime_max_phys_footprint)
    }

    private nonisolated(unsafe) static var restarted = false

    /// Start the peak over from the footprint as it is: `proc_reset_footprint_interval`,
    /// which libproc exports and its header does not.
    static func restartPeak() {
        typealias Reset = @convention(c) (Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_reset_footprint_interval") else { return }
        restarted = unsafeBitCast(symbol, to: Reset.self)(getpid()) == 0
    }

    /// Hand back what the writing freed: a freed block stays in the footprint
    /// until the allocator is asked to give it up.
    static func letGo() {
        for _ in 0..<3 { malloc_zone_pressure_relief(nil, 0) }
    }

    /// `events` events spread over the last `spanDays`, oldest first, in
    /// batches, so that what writing holds is a batch. Two in five are focus
    /// events, and the rest are pulses in the health record when `health`
    /// (the whole record, as the roll reads it) and chains in the logbook
    /// when not (the coach's ring, as the prewarmer reads it).
    static func write(events: Int, spanDays: Double, now: Date, store: ObservationStore, health: Bool) {
        let apps = ["Brave Browser", "T3 Code (Beta)", "Rex Beta", "Claude", "Finder", "Mail", "Messages", "Notes"]
        let span = spanDays * 86_400
        var batch = 0
        for i in 0..<events {
            let t = now.addingTimeInterval(-Double(events - i) * span / Double(events))
            var event = ObservationEvent(t: t, kind: i % 5 < 2 ? .focus : (health ? .pulse : .chain))
            if event.kind == .focus || event.kind == .chain {
                if event.kind == .focus { event.app = apps[i % apps.count] }
                event.source = "chain"
                event.chain = ["a", "b"]
                event.gaps = [0.12, 0.2]
                store.log.append(event)
            } else {
                event.keys = 120 + i % 50
                event.backspaces = 4
                event.clicks = 3
                event.activeMinutes = 1
                event.ikN = 100
                event.ikSum = 18.2
                event.ikSumSq = 4.1
                event.holdN = 100
                event.holdSum = 9.1
                event.holdSumSq = 0.9
                event.keyboards = ["Adv360"]
                event.roles = ["text": 3, "code": 1]
                store.healthLog.append(event)
            }
            batch += 1
            if batch == 2_000 {
                store.log.flush()
                store.healthLog.flush()
                batch = 0
            }
        }
        store.log.flush()
        store.healthLog.flush()
    }
}
