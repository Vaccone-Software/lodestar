import Darwin
import Foundation

/// The system's own word for how short memory is.
///
/// Read from the kernel, because the dispatch source does not say: the
/// kernel signals processes a few at a time, so a process can sit through a
/// warning and hear nothing of it (seen 2026-11-05: level 2 with no signal to
/// Lodestar).
public enum MemoryLevel: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var name: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    public static var current: MemoryLevel {
        MemoryLevel(rawValue: Int(MemoryReport.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)) ?? .normal
    }
}

/// One application's share: its helpers counted with it, because a browser
/// is sixty processes and none of them looks large alone.
public struct MemoryApp: Equatable, Sendable {
    public var name: String
    public var mb: Int

    public init(name: String, mb: Int) {
        self.name = name
        self.mb = mb
    }
}

/// What memory looked like at one moment.
public struct MemoryReading: Equatable, Sendable {
    /// What Activity Monitor calls Memory, for this process.
    public var footprintMB: Int
    public var peakMB: Int
    public var level: MemoryLevel
    /// The kernel's own percentage of memory available.
    public var freePercent: Int
    public var compressorMB: Int
    public var swapMB: Int
    /// The largest applications this user runs. Another user's processes
    /// cannot be read, WindowServer's among them.
    public var top: [MemoryApp]

    public init(footprintMB: Int, peakMB: Int, level: MemoryLevel, freePercent: Int,
                compressorMB: Int, swapMB: Int, top: [MemoryApp]) {
        self.footprintMB = footprintMB
        self.peakMB = peakMB
        self.level = level
        self.freePercent = freePercent
        self.compressorMB = compressorMB
        self.swapMB = swapMB
        self.top = top
    }

    /// "basalt-mac 7040, lodestar 3536", for one field of a log line.
    public var topLine: String {
        top.map { "\($0.name) \($0.mb)" }.joined(separator: ", ")
    }
}

/// Reads memory for the log. Nothing here is fast enough to do on the main
/// thread for no reason: the application scan is a few system calls per
/// process.
public enum MemoryReport {
    public static func read(topCount: Int = 6) -> MemoryReading {
        let own = ownFootprintMB()
        return MemoryReading(footprintMB: own.now, peakMB: own.peak, level: .current,
                             freePercent: Int(sysctlInt32("kern.memorystatus_level") ?? -1),
                             compressorMB: compressorMB(), swapMB: swapMB(),
                             top: largest(runningProcesses(), count: topCount))
    }

    /// This process's physical footprint now and at its peak, in MB.
    public static func ownFootprintMB() -> (now: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (-1, -1) }
        return (Int(info.phys_footprint >> 20), Int(info.ledger_phys_footprint_peak >> 20))
    }

    /// The name a process's memory is counted under: the outermost app
    /// bundle on its path, so a helper counts with its app, or else the
    /// executable's own name.
    public static func appName(path: String) -> String {
        let parts = path.split(separator: "/")
        if let bundle = parts.first(where: { $0.hasSuffix(".app") }) { return String(bundle.dropLast(4)) }
        return parts.last.map(String.init) ?? path
    }

    /// The largest applications, each process's footprint added to its
    /// application's. Ties break on the name, so a line reads the same way
    /// from one reading to the next.
    public static func largest(_ processes: [(path: String, bytes: UInt64)], count: Int) -> [MemoryApp] {
        var bytes: [String: UInt64] = [:]
        for process in processes { bytes[appName(path: process.path), default: 0] += process.bytes }
        return bytes.map { MemoryApp(name: $0.key, mb: Int($0.value >> 20)) }
            .sorted { $0.mb != $1.mb ? $0.mb > $1.mb : $0.name < $1.name }
            .prefix(count).map { $0 }
    }

    /// Every process whose footprint this user may read, with its path.
    static func runningProcesses() -> [(path: String, bytes: UInt64)] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        // Room for what starts between asking how many and asking which.
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let found = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard found > 0 else { return [] }
        var out: [(path: String, bytes: UInt64)] = []
        out.reserveCapacity(Int(found))
        var buffer = [CChar](repeating: 0, count: 4096)    // PROC_PIDPATHINFO_MAXSIZE
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard read == 0 else { continue }
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            out.append((String(decoding: path, as: UTF8.self), usage.ri_phys_footprint))
        }
        return out
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func compressorMB() -> Int {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(UInt64(stats.compressor_page_count) * UInt64(getpagesize()) >> 20)
    }

    private static func swapMB() -> Int {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return -1 }
        return Int(usage.xsu_used >> 20)
    }
}

/// When the memory watch writes a line: at its first look, whenever the level
/// changes, and otherwise every five minutes, about 60 KB of log a day. A
/// freeze leaves no report of what was in memory, so the last of these lines
/// is the record of it.
public struct MemoryLogPlan: Sendable {
    public static let heartbeat: TimeInterval = 5 * 60

    private var lastLine: Date?
    private var lastLevel: MemoryLevel?

    public init() {}

    /// Why a line is due now, or nil when none is.
    public mutating func why(at now: Date, level: MemoryLevel) -> String? {
        defer { lastLevel = level }
        let why: String?
        if lastLine == nil {
            why = "start"
        } else if level != lastLevel {
            why = "level"
        } else if let lastLine, now.timeIntervalSince(lastLine) >= Self.heartbeat {
            why = "beat"
        } else {
            why = nil
        }
        if why != nil { lastLine = now }
        return why
    }
}
