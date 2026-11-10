import Foundation

/// The logs, read a month at a time in the order `Rollup.build` folds them.
///
/// `build` folds every event of both logs sorted by time (a tie keeps the
/// logbook's event before the health record's, and within a log the order
/// `readAll` gives: shards oldest first, the live file, then what is pending).
/// A month's events are a contiguous run of that order, so a month at a time
/// is the same fold, and each month is held as bytes and an index until its
/// events are decoded one by one, in order, and let go.
final class MonthStream {
    private let logs: [EventLog]
    private var manifests: [EventLog.MonthManifest] = []

    /// `logs` in the order their events win a tie: the logbook, then the health record.
    init(_ logs: [EventLog]) { self.logs = logs }

    /// Every month any log has events in, oldest first.
    func months() -> [String] {
        manifests = logs.map { $0.monthManifest() }
        return Set(manifests.flatMap(\.months)).sorted()
    }

    /// The events of `month`, in order, each handed to `body` and let go.
    /// `kinds` limits what is indexed at all. Throws `EventLog.MisplacedLine`
    /// when the stream cannot promise the order.
    func visit(_ month: String, kinds: Set<ObservationEvent.Kind>?,
               _ body: (ObservationEvent) -> Void) throws {
        var held: [EventLog.MonthLines] = []
        for (log, manifest) in zip(logs, manifests) {
            held.append(try log.monthLines(month, manifest: manifest, kinds: kinds))
        }
        struct Place {
            var t: Date
            var log: Int
            var segment: UInt8
            var position: Int
            var index: Int
        }
        var order: [Place] = []
        order.reserveCapacity(held.reduce(0) { $0 + $1.entries.count })
        for (log, lines) in held.enumerated() {
            for (index, entry) in lines.entries.enumerated() {
                order.append(Place(t: entry.t, log: log, segment: entry.segment, position: entry.lo, index: index))
            }
        }
        order.sort {
            if $0.t != $1.t { return $0.t < $1.t }
            if $0.log != $1.log { return $0.log < $1.log }
            if $0.segment != $1.segment { return $0.segment < $1.segment }
            return $0.position < $1.position
        }
        let decoder = EventLog.makeDecoder()
        for place in order {
            let lines = held[place.log]
            if let event = lines.event(lines.entries[place.index], decoder: decoder) { body(event) }
        }
    }
}
