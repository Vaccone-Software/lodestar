import Foundation

/// How much the record may occupy, in bytes, and what each bound is for.
///
/// Two memories, each bounded by size and each saying why. The
/// **behavioral** ring — app switches, hosts, chains, the coach's
/// answers — exists for year-over-year questions and is a profile of
/// hours and hosts on disk, so it is capped where roughly two years fit
/// at today's rate and its months retire oldest first once it is full;
/// the monthly rollup keeps their shape forever. The **health** record —
/// the raw presses and reaches, the pulses and windows extracted from
/// retired months — is the baseline the instrument exists to keep, and
/// nothing is recomputable from a summary of it, so its bound is a
/// safety net a decade out rather than a policy: it is declared here,
/// measured by `healthUsage`, and the instrument will *warn* as it
/// nears it. It never prunes health on its own — a baseline deleted by
/// its own instrument is the one failure this file must make impossible.
public enum Retention {
    /// The behavioral ring: `events.jsonl` and its monthly shards.
    public static let behavioralBytes: Int64 = 256 << 20
    /// The health record: `keys/`, `pointer/`, the health log and its
    /// shards, and `health-*.jsonl.z`.
    public static let healthBytes: Int64 = 1 << 30
    /// The smallest bounds the settings allow. The logbook's still holds
    /// months beyond the coach's ninety-day window at today's rate (about
    /// 85 MB a year on the maker's Mac); the health record's, the better
    /// part of a year (about 300 MB a year there, so the default is nearer
    /// three years out than the decade first assumed).
    public static let logbookMinimumMB = 64
    public static let healthMinimumMB = 256
    /// The fraction of a bound at which the instrument should say so.
    public static let warnFraction = 0.8

    public struct Usage: Equatable {
        public var bytes: Int64
        public var bound: Int64
        public var fraction: Double { bound > 0 ? Double(bytes) / Double(bound) : 0 }
        public var nearBound: Bool { fraction >= Retention.warnFraction }
        public init(bytes: Int64, bound: Int64) {
            self.bytes = bytes
            self.bound = bound
        }
    }

    /// The ring's bytes: the live file and every shard beside it.
    public static func behavioralUsage(in directory: URL, base: String = "events") -> Usage {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let bytes = names
            .filter { $0 == "\(base).jsonl" || ($0.hasPrefix("\(base)-") && $0.hasSuffix(".jsonl")) }
            .reduce(Int64(0)) { $0 + size(directory.appendingPathComponent($1)) }
        return Usage(bytes: bytes, bound: behavioralBytes)
    }

    /// The health record's bytes across its three stores.
    public static func healthUsage(in directory: URL) -> Usage {
        var bytes: Int64 = 0
        for sub in [KeyStore.subdirectory, PointerStore.subdirectory] {
            bytes += directorySize(directory.appendingPathComponent(sub, isDirectory: true))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        bytes += names
            .filter { $0.hasPrefix("health-") && ($0.hasSuffix(".jsonl.z") || $0.hasSuffix(".jsonl")) }
            .reduce(Int64(0)) { $0 + size(directory.appendingPathComponent($1)) }
        return Usage(bytes: bytes, bound: healthBytes)
    }

    /// The warning the bound promises, once the record is near it: nil
    /// until then. It says what is true, that nothing will be trimmed,
    /// because the person is the only one who may delete a baseline.
    public static func healthWarning(in directory: URL, bound: Int64 = healthBytes) -> String? {
        var usage = healthUsage(in: directory)
        usage.bound = bound
        return warning(for: usage)
    }

    static func warning(for usage: Usage) -> String? {
        guard usage.nearBound else { return nil }
        let held = Int((Double(usage.bytes) / 1_048_576).rounded())
        let planned = Int((Double(usage.bound) / 1_048_576).rounded())
        return "The health record holds \(held) MB of the \(planned) MB planned for it. "
            + "Nothing is trimmed on its own"
    }

    static func size(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.reduce(Int64(0)) { $0 + size(url.appendingPathComponent($1)) }
    }
}
