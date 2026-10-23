import AppKit
import LodestarCore

/// The coach's offer, compact: one sentence in the voice, over the row you
/// would take, with a whisper beneath it.
///
/// The row is the launcher's own raised row, because an offer is a row you
/// take: the app's icon, its name, the address on offer in quiet keys, and
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
    static let width: CGFloat = 428
    static let maxWidth: CGFloat = 540

    static func build(_ offer: Offer) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let voice = NSTextField(wrappingLabelWithString: offer.sentence)
        voice.setRole(.quietVoice)
        voice.textColor = BarTheme.ink
        voice.preferredMaxLayoutWidth = maxWidth - textInset * 2
        voice.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(voice)

        let row = OfferRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = Grid.part
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        // A breath's apps overlap the way their windows will stand together.
        let icons = NSStackView()
        icons.orientation = .horizontal
        icons.spacing = -Grid.half
        for image in offer.icons.prefix(2) {
            let view = NSImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: Grid.section).isActive = true
            view.heightAnchor.constraint(equalToConstant: Grid.section).isActive = true
            icons.addArrangedSubview(view)
        }
        if !offer.icons.isEmpty { line.addArrangedSubview(icons) }
        let name = NSTextField(labelWithString: offer.name)
        name.setRole(.body)
        name.textColor = BarTheme.ink
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        line.addArrangedSubview(name)
        // The address on offer, quiet: what you would press later, not now.
        line.addArrangedSubview(Keycaps.strokes(offer.address, quiet: true))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(spacer)
        let accept = Keycaps.CapGroup(strokes: Keycaps.strokes(["lode"], double: true, lit: true),
                                      action: offer.accept)
        accept.setAccessibilityLabel("Accept")
        line.addArrangedSubview(accept)

        // The whisper: the record, and the way out, both quiet.
        let whisper = NSStackView()
        whisper.orientation = .horizontal
        whisper.alignment = .centerY
        whisper.spacing = Grid.close
        whisper.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(whisper)
        let record = NSTextField(labelWithString: offer.record)
        record.setRole(.meta)
        record.textColor = BarTheme.secondaryColor
        record.lineBreakMode = .byTruncatingTail
        record.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        whisper.addArrangedSubview(record)
        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        whisper.addArrangedSubview(gap)
        let decline = Keycaps.CapGroup(strokes: Keycaps.strokes(["lode", "⌫"]), action: offer.decline)
        decline.setAccessibilityLabel("Not now")
        whisper.addArrangedSubview(decline)
        let notNow = NSTextField(labelWithString: "Not now")
        notNow.setRole(.meta)
        notNow.textColor = BarTheme.secondaryColor
        whisper.addArrangedSubview(notNow)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            voice.topAnchor.constraint(equalTo: card.topAnchor, constant: Grid.part),
            voice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            voice.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -textInset),
            row.topAnchor.constraint(equalTo: voice.bottomAnchor, constant: Grid.close),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: BarTheme.rowHeight),
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Grid.part),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Grid.part),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
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

    /// The offer's row: always raised, the way the launcher raises the row
    /// the hand is about to take.
    final class OfferRow: RaisedRow {
        override init(frame: NSRect) {
            super.init(frame: frame)
            setupRaised()
            applyRaised(true)
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
