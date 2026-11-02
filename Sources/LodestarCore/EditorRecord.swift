import Foundation

/// What the observation record says the editor did, folded for
/// `lodestar observations`.
///
/// Two eras are in the record and they are never mixed in one rate. Before
/// `stood`, a mark was counted `shown` the instant it was placed, keyed by
/// its words and where it stood, so typing before it counted it again and
/// a field that flickered counted every mark again: 3,314 marks were
/// shown to 175 fixed (5%), and the number meant nothing. From the first
/// `stood` event on, a mark is counted once, when it ends, if it stood a
/// second or more or was answered, and ends in exactly one outcome
/// (`EditorMarkLedger`). The first `stood` event marks the cut; what came
/// before it is read as it was written and labelled so.
///
/// The draft is kept out of both. Its marks are drawn on its own glass,
/// are answered in the same breath they are read, and have no standing
/// life of their own to measure, so its fixes are a line of their own
/// rather than a numerator over the field's denominator.
public struct EditorRecord: Equatable {
    /// Where the draft's events are written.
    public static let draftApp = "draft"

    /// Counts of one kind of mark, or one app's, in the honest era.
    public struct Tally: Equatable {
        /// Marks that stood a second or more, or were answered.
        public var shown = 0
        /// Fixed by Lodestar (the lens, the card, ⏎), before any taken back.
        public var applied = 0
        public var takenBack = 0
        /// Kept as written, or learned.
        public var kept = 0
        public var byHand = 0
        public var edited = 0
        public var left = 0
        /// Marks the editor withdrew itself: not part of `shown`.
        public var withdrawn = 0

        /// Fixed by Lodestar and left fixed.
        public var fixed: Int { max(0, applied - takenBack) }

        /// What the hand wanted done, whoever did it: fixed by Lodestar and
        /// left fixed, or fixed by hand.
        public var useful: Int { fixed + byHand }

        /// The share of marks shown that `count` is, or nil with none shown.
        public func share(_ count: Int) -> Double? {
            shown > 0 ? Double(count) / Double(shown) : nil
        }
    }

    /// The counts as the record kept them before `stood`.
    public struct Legacy: Equatable {
        public var shown = 0
        public var applied = 0
        public var kept = 0
        public var undone = 0
        public var learned = 0
        public var inSentence = 0
        public var byMouse = 0
        public var byKeys = 0
        public var spellingShown = 0, spellingApplied = 0
        public var grammarShown = 0, grammarApplied = 0
        public var apps: [String: (shown: Int, applied: Int, kept: Int)] = [:]

        public static func == (a: Legacy, b: Legacy) -> Bool {
            a.shown == b.shown && a.applied == b.applied && a.kept == b.kept && a.undone == b.undone
                && a.learned == b.learned && a.inSentence == b.inSentence
                && a.byMouse == b.byMouse && a.byKeys == b.byKeys
                && a.apps.mapValues { [$0.shown, $0.applied, $0.kept] }
                    == b.apps.mapValues { [$0.shown, $0.applied, $0.kept] }
        }

        public var isEmpty: Bool { shown == 0 && applied == 0 && kept == 0 && undone == 0 }
    }

    /// The draft's own line.
    public struct Draft: Equatable {
        public var applied = 0
        public var undone = 0
        public var kept = 0
        public var fixed: Int { max(0, applied - undone) }
        public var isEmpty: Bool { applied == 0 && undone == 0 && kept == 0 }
    }

    /// The first `stood` event: the honest era begins here.
    public let since: Date?
    public let total: Tally
    public let byKind: [String: Tally]
    public let byApp: [String: Tally]
    /// How long the marks the hand edited had stood before it did:
    /// under 3 seconds, 3 to 30, and longer.
    public let handStood: [Int]
    public let legacy: Legacy
    public let draft: Draft

    public static let handBuckets = ["under 3 s", "3 to 30 s", "over 30 s"]

    public init(events: [ObservationEvent]) {
        let edits = events.filter { $0.kind == .editor }.sorted { $0.t < $1.t }
        let cut = edits.first { $0.action == "stood" && $0.app != Self.draftApp }?.t
        since = cut
        var total = Tally(), kinds: [String: Tally] = [:], apps: [String: Tally] = [:]
        var hand = [0, 0, 0]
        var legacy = Legacy(), draft = Draft()

        func bump(_ event: ObservationEvent, kind: String, _ change: (inout Tally) -> Void) {
            change(&total)
            change(&kinds[kind, default: Tally()])
            change(&apps[event.app ?? "?", default: Tally()])
        }

        for event in edits {
            let app = event.app ?? "?"
            if app == Self.draftApp {
                switch event.action {
                case "applied": draft.applied += 1
                case "undone": draft.undone += 1
                case "dismissed": draft.kept += 1
                default: break
                }
                continue
            }
            if let cut, event.t >= cut {
                let kind = event.rec ?? "?"
                switch event.action {
                case "stood": bump(event, kind: kind) { $0.shown += 1 }
                case "applied": bump(event, kind: kind) { $0.applied += 1 }
                case "undone": bump(event, kind: kind) { $0.takenBack += 1 }
                case "dismissed": bump(event, kind: event.source ?? "?") { $0.kept += 1 }
                case "byhand": bump(event, kind: kind) { $0.byHand += 1 }
                case "changed": bump(event, kind: kind) { $0.edited += 1 }
                case "left": bump(event, kind: kind) { $0.left += 1 }
                case "withdrawn": bump(event, kind: kind) { $0.withdrawn += 1 }
                default: break
                }
                if event.action == "byhand" || event.action == "changed", let seconds = event.seconds {
                    hand[seconds < 3 ? 0 : seconds < 30 ? 1 : 2] += 1
                }
            } else {
                switch event.action {
                case "shown":
                    legacy.shown += 1
                    legacy.apps[app, default: (0, 0, 0)].shown += 1
                    if event.rec == "spelling" { legacy.spellingShown += 1 }
                    if event.rec == "grammar" { legacy.grammarShown += 1 }
                case "applied":
                    legacy.applied += 1
                    legacy.apps[app, default: (0, 0, 0)].applied += 1
                    if event.rec == "spelling" { legacy.spellingApplied += 1 }
                    if event.rec == "grammar" { legacy.grammarApplied += 1 }
                    if event.row == "mouse" { legacy.byMouse += 1 } else { legacy.byKeys += 1 }
                case "dismissed":
                    legacy.kept += 1
                    legacy.apps[app, default: (0, 0, 0)].kept += 1
                    if event.rec == "name" { legacy.learned += 1 } else { legacy.inSentence += 1 }
                    if event.row == "mouse" { legacy.byMouse += 1 } else { legacy.byKeys += 1 }
                case "undone": legacy.undone += 1
                default: break
                }
            }
        }
        self.total = total
        byKind = kinds
        byApp = apps
        handStood = hand
        self.legacy = legacy
        self.draft = draft
    }
}

// MARK: - The report

extension EditorRecord {
    /// The editor's section of `lodestar observations`, a line at a time:
    /// the honest era first, the older counts apart beneath it under their
    /// own label, the draft on a line of its own.
    public func report() -> [String] {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        func percent(_ count: Int, of tally: Tally) -> String {
            tally.share(count).map { "\(Int(($0 * 100).rounded()))%" } ?? "-"
        }
        func day(_ date: Date) -> String {
            let calendar = Calendar.current
            return "\(calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1]) \(calendar.component(.day, from: date))"
        }
        var lines: [String] = []
        if let since {
            let t = total
            lines.append("  since \(day(since)), a mark counts once it has stood a second or been answered")
            lines.append("  \(t.shown) marks shown · \(percent(t.useful, of: t)) useful"
                         + " (\(percent(t.fixed, of: t)) fixed by Lodestar + \(percent(t.byHand, of: t)) fixed by hand)")
            lines.append("  edited into something else \(percent(t.edited, of: t))"
                         + " · left standing \(percent(t.left, of: t))"
                         + " · kept \(percent(t.kept, of: t))"
                         + " · \(t.takenBack) fixes taken back · \(t.withdrawn) withdrawn by the editor, not counted")
            for kind in ["spelling", "grammar"] {
                guard let k = byKind[kind], k.shown > 0 else { continue }
                lines.append("  \(pad(kind, 10))\(pad("\(k.shown) shown", 11))\(pad("\(percent(k.useful, of: k)) useful", 12))"
                             + "fixed \(percent(k.fixed, of: k)) · by hand \(percent(k.byHand, of: k))"
                             + " · edited \(percent(k.edited, of: k)) · left \(percent(k.left, of: k))"
                             + " · kept \(percent(k.kept, of: k))")
            }
            if handStood.reduce(0, +) > 0 {
                let spans = zip(Self.handBuckets, handStood).map { "\($1) \($0)" }.joined(separator: " · ")
                lines.append("  the hand's own edits came after the mark had stood: \(spans)")
            }
            let busiest = byApp.filter { $0.value.shown > 0 }.sorted { ($0.value.shown, $1.key) > ($1.value.shown, $0.key) }
            for (app, a) in busiest.prefix(6) {
                lines.append("  \(pad(app, 22))\(pad("\(a.shown) marks", 11))\(pad("\(percent(a.useful, of: a)) useful", 12))"
                             + "\(a.fixed) fixed · \(a.byHand) by hand · \(a.edited) edited · \(a.left) left · \(a.kept) kept")
            }
        }
        if !legacy.isEmpty {
            let old = legacy
            let share = old.shown > 0 ? " · \(Int(Double(old.applied) / Double(old.shown) * 100))% of marks fixed" : ""
            let until = since.map { " before " + day($0) } ?? ""
            lines.append("  counted when placed, not comparable with the above\(until):")
            lines.append("    \(old.shown) marks · \(old.applied) fixed · \(old.kept) kept as written"
                         + " · \(old.undone) fixes taken back\(share)")
            lines.append("    spelling \(old.spellingShown) shown, \(old.spellingApplied) fixed"
                         + " · grammar \(old.grammarShown) shown, \(old.grammarApplied) fixed"
                         + " · kept: \(old.learned) words learned, \(old.inSentence) in their sentence")
            lines.append("    answered by the keys \(old.byKeys) · by the mouse \(old.byMouse)")
            for (app, a) in old.apps.sorted(by: { ($0.value.shown, $1.key) > ($1.value.shown, $0.key) }).prefix(6)
            where a.shown > 0 {
                lines.append("    \(pad(app, 22))\(pad("\(a.shown) marks", 11))\(pad("\(a.applied) fixed", 10))\(a.kept) kept")
            }
        }
        if !draft.isEmpty {
            lines.append("  the draft, apart: \(draft.fixed) fixed (\(draft.undone) taken back) · \(draft.kept) kept as written")
        }
        return lines
    }
}
