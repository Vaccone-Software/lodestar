import Foundation
import LodestarCore

/// The ledgers of fields the hand has gone away from with marks still
/// standing, kept for a while in case it comes back.
///
/// A draft that is not sent is left and returned to again and again (the
/// log has the hand in and out of one Telegram composer all day), and each
/// return placed the same marks and counted them again, since the ledger
/// was thrown away on leaving while the model's answers stayed cached. A
/// field left now is shelved with its ledger, and the ledger is resumed if
/// the field comes back, so a mark is one mark however often the hand
/// looks in on it.
///
/// A shelved ledger's clock is stopped (`EditorMarkLedger.hide`), so a mark
/// stands only for the time it was on the screen, and a mark ends only
/// when its field comes back with its text gone, or when the shelf lets it
/// go: after `keep`, when the shelf is over `capacity`, or when the editor
/// is switched off. It then ends with the time it really stood.
///
/// What is kept is the field's text, which the controller already holds
/// for the live field, in memory and for at most ten minutes. Nothing from
/// here is ever written but the endings.
struct EditorMarkShelf {
    /// How long a left field's marks are held for its return. A draft left
    /// for a meeting is back inside this; one left for the afternoon was
    /// sent, or forgotten, and its marks end as left.
    static let keep: TimeInterval = 600
    /// Fields held at once, the oldest let go first: the number a hand
    /// plausibly has half-written, and a bound whatever it does.
    static let capacity = 8

    struct Parked {
        var ledger: EditorMarkLedger
        /// The field as it was left: its element, its text, its app.
        let field: EditorField
        /// The issues the text had, for judging a mark the hand was in the
        /// middle of editing when it left.
        let issues: [EditorIssue]
        /// When the marks came down, and when the shelf took them.
        let hiddenAt: Date
        let parkedAt: Date
    }

    /// The marks that ended, and where.
    struct Ended {
        let app: String
        let endings: [EditorMarkLedger.Ending]
    }

    /// A field that came back: the ledger it left, if the shelf had one for
    /// it, and what its coming back ended.
    struct Resumed {
        var parked: Parked?
        var ended: [Ended] = []
    }

    private(set) var parked: [Parked] = []

    var count: Int { parked.count }

    /// Does `read` stand where `held` was left? The same app, and the text it
    /// had or nearly so (`EditorController.similar`, the rule that calls a
    /// rebuilt element the same field): a field's element is rebuilt by the
    /// apps that rebuild it, so it is a tie-break and no key, and a field
    /// with another text is another field, whatever its element.
    private static func matches(_ held: EditorField, _ read: EditorField) -> Bool {
        held.pid == read.pid && held.bundleID == read.bundleID && EditorController.similar(held.text, read.text)
    }

    /// A field left with its ledger. A ledger with nothing standing is not
    /// kept. The marks came down at `hiddenAt`, which is before `now` for a
    /// field that went silent and was cleared when the grace ran out.
    mutating func park(_ ledger: EditorMarkLedger, of field: EditorField, issues: [EditorIssue],
                       hiddenAt: Date, at now: Date) -> [Ended] {
        guard ledger.count > 0 else { return [] }
        var held = ledger
        held.hide(at: hiddenAt)
        parked.append(Parked(ledger: held, field: field, issues: issues, hiddenAt: hiddenAt, parkedAt: now))
        var ended = expire(at: now)
        while parked.count > Self.capacity { ended.append(finish(parked.removeFirst(), at: now)) }
        return ended
    }

    /// A field was read that is not the one before it: is it one that was
    /// left? The best match is taken off the shelf, an exact text before a
    /// near one and the same element before another. A shelved field with
    /// the same element and a text that is no longer near was written over
    /// in place (sent, or cleared): its text is gone, and its marks end now.
    mutating func resume(for read: EditorField, at now: Date) -> Resumed {
        var result = Resumed()
        func rank(_ held: Parked) -> Int {
            (held.field.text == read.text ? 2 : 0) + (held.field.isSame(as: read) ? 1 : 0)
        }
        let best = parked.indices.filter { Self.matches(parked[$0].field, read) }
            .max { (rank(parked[$0]), $0) < (rank(parked[$1]), $1) }
        if let best { result.parked = parked.remove(at: best) }
        for index in parked.indices.reversed()
        where parked[index].field.isSame(as: read) && !Self.matches(parked[index].field, read) {
            result.ended.append(finish(parked.remove(at: index), at: now))
        }
        return result
    }

    /// The marks whose keeping has run out end as left.
    mutating func expire(at now: Date) -> [Ended] {
        var ended: [Ended] = []
        for index in parked.indices.reversed() where now.timeIntervalSince(parked[index].parkedAt) >= Self.keep {
            ended.append(finish(parked.remove(at: index), at: now))
        }
        return ended
    }

    /// Everything on the shelf ends: the editor was switched off.
    mutating func drain(at now: Date) -> [Ended] {
        defer { parked = [] }
        return parked.map { finish($0, at: now) }
    }

    private func finish(_ held: Parked, at now: Date) -> Ended {
        var ledger = held.ledger
        return Ended(app: held.field.appName,
                     endings: ledger.clear(text: held.field.text, all: held.issues, at: now, until: held.hiddenAt))
    }
}
