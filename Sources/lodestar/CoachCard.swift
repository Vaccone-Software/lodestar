import AppKit
import LodestarCore

/// The coach's offer, compact: one sentence in the voice, over the row you
/// would take, with a whisper beneath it.
///
/// The row is the launcher's own chosen row, the slab, because an offer is a
/// row you take: the app's icon, its name, the address on offer in quiet keys, and
/// the chord that accepts it lit at the end. Nothing else on the card is
/// lit, so the one light means yes. Beneath the row, in the quiet register
/// the chrome whispers in, the record on the left, which wraps and is never
/// cut, and the way out on the right, on the record's first line. It replaced
/// a card of five equal blocks that said the address twice and spent a whole
/// row on each of two words.
enum CoachCard {
    struct Offer {
        var sentence: String
        var icons: [NSImage]
        var name: String
        var address: [String]
        var record: String
        var accept: () -> Void
        var decline: () -> Void
    }

    /// The glass's own inset around the row, so the surface hugs it.
    static let inset = BarTheme.paneInset
    /// The sentence and the whisper sit in from the row's edge by this.
    static let textInset = Grid.part
    /// Wide enough for one sentence of the voice on a line, a row's worth;
    /// a breath's two names and longer address may take it to `maxWidth`.
    static let width = BarTheme.offerWidth
    static let maxWidth = BarTheme.offerMaxWidth

    static func build(_ offer: Offer) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let voice = NSTextField(wrappingLabelWithString: offer.sentence)
        voice.setRole(.quietVoice)
        voice.textColor = BarTheme.ink
        voice.preferredMaxLayoutWidth = maxWidth - textInset * 2
        voice.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(voice)

        // The offer is a row of the row contract, always the slab: a breath's
        // apps lead, overlapping the way their windows will stand together;
        // then its name, and 8 after it the address on offer in quiet keys
        // (what you would press later, not now), 4 apart; at the trailing end
        // the chord that accepts it, lit. Nothing else on the card is lit, so
        // the one light means yes.
        let row = OfferRow()
        row.title.stringValue = offer.name
        if !offer.icons.isEmpty { row.setLead(RowIcon.overlapped(offer.icons)) }
        let accept = Keycaps.CapGroup(strokes: Keycaps.strokes(["lode"], double: true, lit: true),
                                      action: offer.accept)
        accept.setAccessibilityLabel("Accept")
        row.titleLine.addArrangedSubview(Keycaps.strokes(offer.address, quiet: true))
        row.setTrailing([accept])
        card.addSubview(row)

        // The whisper: the record, and the way out, both quiet. The record is a
        // sentence, so it wraps within its own column, from the card's inset to
        // 8 before the way out, and is never cut; the way out stands at the
        // trailing end on the record's first line, its words on the baseline of
        // the keys they stand beside. The card grows to hold every line.
        let decline = Keycaps.CapGroup(strokes: Keycaps.strokes(["lode", "⌫"]), action: offer.decline)
        decline.setAccessibilityLabel("Not now")
        let notNow = KeyWords("Not now")
        notNow.setContentCompressionResistancePriority(.required, for: .horizontal)
        let way = NSStackView(views: [decline, notNow])
        way.orientation = .horizontal
        way.alignment = .centerY
        way.spacing = Grid.close
        way.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(way)
        let record = KeyWords(offer.record)
        record.column = { [unowned way] in maxWidth - textInset * 2 - way.fittingSize.width - Grid.close }
        record.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.addSubview(record)
        // On one line the record keeps 16 from the way out, as it always has;
        // only a record that must wrap gives up the other 8.
        let ease = record.trailingAnchor.constraint(lessThanOrEqualTo: way.leadingAnchor, constant: -Grid.close * 2)
        ease.priority = NSLayoutConstraint.Priority(700)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            voice.topAnchor.constraint(equalTo: card.topAnchor, constant: Grid.part),
            voice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            voice.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -textInset),
            row.topAnchor.constraint(equalTo: voice.bottomAnchor, constant: Grid.close),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            record.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Grid.close),
            record.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            record.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Grid.tight),
            record.trailingAnchor.constraint(lessThanOrEqualTo: way.leadingAnchor, constant: -Grid.close),
            ease,
            way.topAnchor.constraint(equalTo: record.topAnchor),
            way.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -textInset),
        ])
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("\(offer.sentence). \(offer.record.replacingOccurrences(of: noBreak, with: " "))")
        return card
    }

    /// The offer's row: always the slab, the way the launcher's chosen row is
    /// the one the hand is about to take. A card's row, so its title is the
    /// label.
    final class OfferRow: ListRow {
        init() {
            super.init(height: BarTheme.rowHeight, titleRole: .label)
            choose(true)
        }

        required init?(coder: NSCoder) { nil }
    }

    /// An app as the card names it: the observation layer keeps names
    /// lowercase, so an all-lowercase name is given its capitals back.
    static func displayName(_ name: String) -> String {
        guard name == name.lowercased() else { return name }
        return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The record's first clause: the count, without the rest of the sums. A
    /// figure is never parted from its label when the record wraps: each number
    /// is joined to the word before it and the one after it (a count to its
    /// unit, "12" to "times") with no-break spaces, a figure that ends in "×"
    /// to the word before it only, and a comma is a place the line may break.
    static func record(from evidence: String) -> String {
        let first = evidence.components(separatedBy: " · ").first ?? evidence
        return unbroken(first.trimmingCharacters(in: .whitespaces))
    }

    static let noBreak = "\u{00A0}"

    static func unbroken(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        func figure(_ word: String) -> Bool { word.contains(where: \.isNumber) }
        var out = ""
        for (index, word) in words.enumerated() {
            if index > 0 {
                let before = words[index - 1]
                let joined = !before.hasSuffix(",")
                    && (figure(word) || (figure(before) && !before.hasSuffix("×")))
                out += joined ? noBreak : " "
            }
            out += word
        }
        return out
    }
}
