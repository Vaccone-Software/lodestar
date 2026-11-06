import Foundation
import LodestarCore
import LodestarEars

/// Keeps a record of memory in the log, so a freeze can be read afterward.
///
/// On 2026-11-05 the Mac hung and was forced off, and nothing could say what
/// had been in memory: a forced power-off writes no report, and the reports
/// from earlier days were taken for other reasons. A line every five minutes
/// is the answer to "was it us?": Lodestar's footprint, what MLX holds of it,
/// the system's level, and the largest applications beside it.
///
/// On a queue of its own, so a slow scan never touches the main thread.
final class MemoryWatch {
    /// How often the level is looked at. The heartbeat is `MemoryLogPlan`'s.
    static let look: TimeInterval = 15

    private let queue = DispatchQueue(label: "lodestar.memory", qos: .utility)
    private var plan = MemoryLogPlan()
    private var timer: DispatchSourceTimer?
    private var signal: DispatchSourceMemoryPressure?
    private let level: () -> MemoryLevel
    private let read: () -> MemoryReading
    private let mlx: () -> (activeMB: Int, cacheMB: Int)?

    init(level: @escaping () -> MemoryLevel = { .current },
         read: @escaping () -> MemoryReading = { MemoryReport.read() },
         mlx: @escaping () -> (activeMB: Int, cacheMB: Int)? = MLXCap.reading) {
        self.level = level
        self.read = read
        self.mlx = mlx
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The first look waits for the launch to be over.
        timer.schedule(deadline: .now() + 30, repeating: Self.look, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.beat(at: Date()) }
        timer.resume()
        self.timer = timer
        let signal = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        signal.setEventHandler { [weak self, weak signal] in
            guard let self, let event = signal?.data else { return }
            self.write(why: event.contains(.critical) ? "signal critical"
                : event.contains(.warning) ? "signal warning" : "signal normal")
        }
        signal.resume()
        self.signal = signal
    }

    /// Runs on the queue, or in a test on whichever thread called it.
    func beat(at now: Date) {
        if let why = plan.why(at: now, level: level()) { write(why: why) }
    }

    private func write(why: String) {
        let reading = read()
        let mlx = self.mlx()
        Log.info("memory", ["why": why,
                            "footprint-mb": reading.footprintMB,
                            "peak-mb": reading.peakMB,
                            "mlx-active-mb": mlx.map { String($0.activeMB) } ?? "none",
                            "mlx-cache-mb": mlx.map { String($0.cacheMB) } ?? "none",
                            "level": reading.level.name,
                            "free-pct": reading.freePercent,
                            "compressor-mb": reading.compressorMB,
                            "swap-mb": reading.swapMB,
                            "top": reading.topLine])
    }
}
