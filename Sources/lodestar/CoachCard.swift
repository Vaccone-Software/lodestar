import AppKit
import LodestarCore

/// The coach's offer, compact: one sentence in the voice, over the row you
/// would take, with a whisper beneath it.
///
/// The row is the launcher's own chosen row, the slab, because an offer is a
/// row you take: the app's icon, its name, the address on offer in quiet keys, and
/// the chord that accepts it lit at the end. Nothing else on the card is
/// lit, so the one light means yes. Beneath the row, in the quiet register
/// the chrome whispers in, the record on the left and the way out on the
/// right. It replaced a card of five equal blocks that said the address
/// twice and spent a whole row on each of two words.
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
        // then its name; at the end the address on offer in quiet keys (what
        // you would press later, not now) and the chord that accepts it, lit,
        // last. Nothing else on the card is lit, so the one light means yes.
        let row = OfferRow()
        row.title.stringValue = offer.name
        if !offer.icons.isEmpty { row.setLead(RowIcon.overlapped(offer.icons)) }
        let accept = Keycaps.CapGroup(strokes: Keycaps.strokes(["lode"], double: true, lit: true),
                                      action: offer.accept)
        accept.setAccessibilityLabel("Accept")
        row.setTrailing([Keycaps.strokes(offer.address, quiet: true), accept])
        card.addSubview(row)

        // The whisper: the record, and the way out, both quiet, on the baseline
        // of the keys they stand beside. The record stays one line, cut at the
        // tail only past the card's width.
        let whisper = NSStackView()
        whisper.orientation = .horizontal
        whisper.alignment = .centerY
        whisper.spacing = Grid.close
        whisper.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(whisper)
        let decline = Keycaps.CapGroup(strokes: Keycaps.strokes(["lode", "⌫"]), action: offer.decline)
        decline.setAccessibilityLabel("Not now")
        let record = KeyWords(offer.record)
        record.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        whisper.addArrangedSubview(record)
        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        whisper.addArrangedSubview(gap)
        whisper.addArrangedSubview(decline)
        whisper.addArrangedSubview(KeyWords("Not now"))

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            voice.topAnchor.constraint(equalTo: card.topAnchor, constant: Grid.part),
            voice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            voice.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -textInset),
            row.topAnchor.constraint(equalTo: voice.bottomAnchor, constant: Grid.close),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            whisper.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Grid.close),
            whisper.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            whisper.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -textInset),
            whisper.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Grid.tight),
        ])
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("\(offer.sentence). \(offer.record)")
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

    /// The record's first clause: the count, without the rest of the sums.
    static func record(from evidence: String) -> String {
        let first = evidence.components(separatedBy: " · ").first ?? evidence
        return first.trimmingCharacters(in: .whitespaces)
    }
}
