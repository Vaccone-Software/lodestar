import XCTest
@testable import LodestarCore

/// What sealing costs a save. A save happens on every summon (usage) and park,
/// on the main thread, so the sealed write must stay within a whisker of the
/// plaintext one it replaced. The comparison is made in the same process on the
/// same disk: the old save (pretty JSON, an atomic durable write, the mode, the
/// backup flag) against `StateStore.save()` of the same state.
///
/// The figures print; the assertion is a bound on what sealing *adds*, loose
/// enough for a busy machine and tight enough to catch work that should not be
/// there (a keychain call, a second write).
final class StateSaveCostTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-statecost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// About what a long-lived install holds: 30 saved addresses of four
    /// windows with titles that are URLs and file names, 250 apps in the
    /// frecency table, 40 spent meeting occurrences.
    private func realisticState() -> PersistedState {
        var state = PersistedState()
        for index in 0..<30 {
            let members = (0..<4).map { member in
                BreathMember(windowID: UInt32(index * 10 + member), bundleID: "com.example.app\(member)",
                             appName: "Application \(member)",
                             title: "https://example.com/projects/\(index)/documents/report-\(member).html — Example",
                             frame: CGRect(x: 10 * member, y: 20, width: 800, height: 600))
            }
            state.breaths.append(BreathRecord(path: "g\(index)", orientation: "horizontal", members: members))
        }
        state.latestBreath = "g3"
        state.usage = Dictionary(uniqueKeysWithValues: (0..<250).map {
            ("com.example.bundle\($0)", UsageRecord(count: $0 % 40, last: Date(timeIntervalSince1970: 1_700_000_000 + Double($0))))
        })
        state.meetingSpent = (0..<40).map { "meeting-\($0)" }
        state.walkCompletedVersion = "0.50.0"
        return state
    }

    private static func cpu() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) * 1e3 + Double(spec.tv_nsec) / 1e6
    }

    private func figures(_ samples: [(wall: Double, cpu: Double)]) -> (wall: Double, p95: Double, cpu: Double) {
        let walls = samples.map(\.wall).sorted()
        let cpus = samples.map(\.cpu).sorted()
        return (walls[walls.count / 2], walls[Int(Double(walls.count) * 0.95)], cpus[cpus.count / 2])
    }

    func testASealedSaveCostsLittleMoreThanThePlaintextOne() throws {
        let reps = 200
        let state = realisticState()

        let plainFile = directory.appendingPathComponent("plain.json")
        let file = directory.appendingPathComponent("state.json")
        let store = SealedFixture.stateStore(file)
        for breath in state.breaths { store.setBreath(breath) }
        for bundle in (state.usage ?? [:]).keys { store.touchUsage(bundle) }
        store.setMeetingSpent(Set(state.meetingSpent ?? []))

        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
        var plain: [(Double, Double)] = []
        var sealed: [(Double, Double)] = []
        var plainBytes = 0
        // Interleaved, so a disk that is busy for a moment is busy for both.
        for _ in 0..<reps {
            // The save this replaces, as it was: pretty JSON, durable atomic write, mode, backup flag.
            var (wall, cpu) = (now(), Self.cpu())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            plainBytes = data.count
            try DurableFile.write(data, to: plainFile, newFileMode: 0o600)
            Paths.restrict(plainFile)
            Paths.excludeFromBackup(plainFile)
            plain.append((now() - wall, Self.cpu() - cpu))

            // The save as it is.
            (wall, cpu) = (now(), Self.cpu())
            store.save()
            sealed.append((now() - wall, Self.cpu() - cpu))
        }
        let sealedBytes = try Data(contentsOf: SealedFixture.sealedState(file)).count

        let before = figures(plain.map { (wall: $0.0, cpu: $0.1) })
        let after = figures(sealed.map { (wall: $0.0, cpu: $0.1) })
        print(String(format: "state save, %d reps, 30 breaths + 250 usage (%d bytes plaintext pretty, %d sealed): "
                     + "plaintext median %.2f ms (p95 %.2f, cpu %.2f) | sealed median %.2f ms (p95 %.2f, cpu %.2f)",
                     reps, plainBytes, sealedBytes, before.wall, before.p95, before.cpu, after.wall, after.p95, after.cpu))

        XCTAssertLessThan(after.wall, before.wall + 6, "sealing adds a few hundred microseconds, not milliseconds")
        XCTAssertLessThan(after.cpu, before.cpu + 1.5)
    }

    /// Opening is once per launch, off the main thread; it is measured so the
    /// number is on record.
    func testOpeningTheSealedStateIsFast() throws {
        let file = directory.appendingPathComponent("state.json")
        let seed = SealedFixture.stateStore(file)
        for breath in realisticState().breaths { seed.setBreath(breath) }
        var times: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let store = StateStore(file: file, vault: SealedFixture.vault(directory))
            store.load()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            XCTAssertEqual(store.state.breaths.count, 30)
        }
        times.sort()
        print(String(format: "state open (read, decrypt, decode, refresh the backup): median %.2f ms, p95 %.2f ms",
                     times[times.count / 2], times[Int(Double(times.count) * 0.95)]))
        XCTAssertLessThan(times[times.count / 2], 100)
    }
}
