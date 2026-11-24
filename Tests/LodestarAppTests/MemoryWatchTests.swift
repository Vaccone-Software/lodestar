import MLX
import XCTest
@testable import lodestar
import LodestarCore
@testable import LodestarMLX

final class MemoryWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let reading = MemoryReading(footprintMB: 3536, peakMB: 6900, level: .normal, freePercent: 62,
                                        compressorMB: 4000, swapMB: 0,
                                        top: [MemoryApp(name: "basalt-mac", mb: 7040), MemoryApp(name: "lodestar", mb: 3536)])

    private func lines(during work: () -> Void) -> [String] {
        let lock = NSLock()
        var said: [String] = []
        Log.listener = { line in lock.withLock { said.append(line) } }
        defer { Log.listener = nil }
        work()
        return lock.withLock { said }.filter { $0.contains(" memory ") }
    }

    func testALineSaysWhatAFreezeWouldTakeWithIt() throws {
        let reading = self.reading
        let watch = MemoryWatch(level: { .normal }, read: { reading }, models: {
            ModelsStats(pid: 4242, footprintMB: 5120, mlxActiveMB: 2486, mlxCacheMB: 64, languageModels: 1, ear: false)
        })
        let said = lines { watch.beat(at: start) }
        let line = try XCTUnwrap(said.first)
        XCTAssertEqual(said.count, 1)
        for field in ["why=start", "footprint-mb=3536", "peak-mb=6900", "models-footprint-mb=5120",
                      "mlx-active-mb=2486", "mlx-cache-mb=64",
                      "level=normal", "free-pct=62", "compressor-mb=4000", "swap-mb=0",
                      "top=\"basalt-mac 7040, lodestar 3536\""] {
            XCTAssertTrue(line.contains(field), "\(field) in \(line)")
        }
    }

    func testBeforeAnyModelLoadsMLXIsNotAsked() throws {
        let reading = self.reading
        let watch = MemoryWatch(level: { .normal }, read: { reading }, models: { nil })
        let line = try XCTUnwrap(lines { watch.beat(at: start) }.first)
        XCTAssertTrue(line.contains("models-footprint-mb=none"), line)
        XCTAssertTrue(line.contains("mlx-active-mb=none"), line)
        XCTAssertTrue(line.contains("mlx-cache-mb=none"), line)
    }

    func testBeatsWriteOnlyWhenALineIsDue() {
        final class Now { var level = MemoryLevel.normal }
        let now = Now()
        let reading = self.reading
        let watch = MemoryWatch(level: { now.level }, read: { reading }, models: { nil })
        let said = lines {
            for second in stride(from: 0.0, to: 600, by: 15) {
                now.level = (second >= 120 && second < 150) ? .warning : .normal
                watch.beat(at: start.addingTimeInterval(second))
            }
        }
        // The start, the warning, its end, and the heartbeat five minutes on.
        XCTAssertEqual(said.map { $0.contains("why=level") }.filter { $0 }.count, 2)
        XCTAssertEqual(said.count, 4, "\(said)")
    }

    /// Ships on: a watch that never starts is the gap it was written to close.
    func testTheAppStartsTheWatchOffTheMainThread() throws {
        let main = DesignDriftTests.code(try String(contentsOf: DesignDriftTests.appSources.appendingPathComponent("main.swift"), encoding: .utf8))
        XCTAssertTrue(main.contains("memoryWatch.start()"))
        let watch = DesignDriftTests.code(try String(contentsOf: DesignDriftTests.appSources.appendingPathComponent("MemoryWatch.swift"), encoding: .utf8))
        XCTAssertTrue(watch.contains("makeTimerSource(queue: queue)"))
        XCTAssertTrue(watch.contains("eventMask: [.normal, .warning, .critical], queue: queue"))
        XCTAssertFalse(watch.contains(".main"), "a scan of every process never runs on main")
    }
}

final class MLXCapTests: XCTestCase {
    /// Every path to a model takes the limit first, and it is said in one
    /// place. Applying it at launch would build the Metal device on Macs that
    /// never load a model.
    func testEveryLoadTakesTheLimitAndNothingElseSetsOne() throws {
        let app = DesignDriftTests.appSources
        let sources = app.deletingLastPathComponent()
        let editor = DesignDriftTests.code(try String(contentsOf: sources.appendingPathComponent("LodestarMLX/MLXLanguageModel.swift"), encoding: .utf8))
        let apply = try XCTUnwrap(editor.range(of: "MLXCap.apply()"))
        let load = try XCTUnwrap(editor.range(of: "LLMModelFactory.shared.loadContainer"))
        XCTAssertTrue(apply.lowerBound < load.lowerBound)
        XCTAssertEqual(editor.components(separatedBy: "loadContainer").count, 2, "and only one way to load")
        let ear = DesignDriftTests.code(try String(contentsOf: sources.appendingPathComponent("LodestarMLX/QwenEar.swift"), encoding: .utf8))
        let earApply = try XCTUnwrap(ear.range(of: "MLXCap.apply()"))
        let earLoad = try XCTUnwrap(ear.range(of: "QwenASRModel.load"))
        XCTAssertTrue(earApply.lowerBound < earLoad.lowerBound)
        let main = DesignDriftTests.code(try String(contentsOf: app.appendingPathComponent("main.swift"), encoding: .utf8))
        XCTAssertFalse(main.contains("MLXCap"), "not at launch")

        for directory in ["lodestar", "LodestarEars", "LodestarMLX", "LodestarModels"] {
            let files = try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" && file.lastPathComponent != "MLXCap.swift" {
                let code = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
                XCTAssertFalse(code.contains("cacheLimit"), file.lastPathComponent)
            }
        }
    }

    func testTheLimitReachesMLX() throws {
        try TimingLane.requireGPU()
        MLXCap.apply()
        XCTAssertEqual(MLXCap.bytes, 64 << 20)
        XCTAssertEqual(Memory.cacheLimit, MLXCap.bytes)
        XCTAssertNotNil(MLXCap.reading())
    }
}
