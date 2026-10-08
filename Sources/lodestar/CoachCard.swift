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
    static let inset: CGFloat = 6
    /// The sentence and the whisper sit in from the row's edge by this.
    static let textInset: CGFloat = 10
    /// Wide enough for one sentence of the voice on a line, a row's worth;
    /// a breath's two names and longer address may take it to `maxWidth`.
    static let width: CGFloat = 428
    static let maxWidth: CGFloat = 540

    static func build(_ offer: Offer) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let voice = NSTextField(wrappingLabelWithString: offer.sentence)
        voice.font = BarTheme.coachVoiceFont
        voice.textColor = .labelColor
        voice.preferredMaxLayoutWidth = maxWidth - textInset * 2
        voice.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(voice)

        let row = OfferRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        // A breath's apps overlap the way their windows will stand together.
        let icons = NSStackView()
        icons.orientation = .horizontal
        icons.spacing = -6
        for image in offer.icons.prefix(2) {
            let view = NSImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 26).isActive = true
            view.heightAnchor.constraint(equalToConstant: 26).isActive = true
            icons.addArrangedSubview(view)
        }
        if !offer.icons.isEmpty { line.addArrangedSubview(icons) }
        let name = NSTextField(labelWithString: offer.name)
        name.font = BarTheme.rowLabelFont
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        line.addArrangedSubview(name)
        // The address on offer, quiet: what you would press later, not now.
        let address = NSStackView()
        address.orientation = .horizontal
        address.spacing = 3
        for key in offer.address {
            let cap = Keycaps.cap(key)
            // Quiet, not gone: a white key on clay fades into the row
            // sooner than a pale one on the night does.
            cap.alphaValue = Tone.systemDark ? 0.5 : 0.8
            address.addArrangedSubview(cap)
        }
        line.addArrangedSubview(address)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(spacer)
        let yes = ["lode", "lode"].map { key -> Keycaps.CapView in
            let cap = Keycaps.cap(key)
            cap.lit = true
            return cap
        }
        let accept = Keycaps.CapGroup(caps: yes, action: offer.accept)
        accept.setAccessibilityLabel("Accept")
        line.addArrangedSubview(accept)

        // The whisper: the record, and the way out, both quiet.
        let whisper = NSStackView()
        whisper.orientation = .horizontal
        whisper.alignment = .centerY
        whisper.spacing = 6
        whisper.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(whisper)
        let record = NSTextField(labelWithString: offer.record)
        record.font = BarTheme.stubDetailFont
        record.textColor = BarTheme.secondaryColor
        record.lineBreakMode = .byTruncatingTail
        record.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        whisper.addArrangedSubview(record)
        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        whisper.addArrangedSubview(gap)
        let decline = Keycaps.CapGroup(caps: ["lode", "⌫"].map { Keycaps.cap($0) }, action: offer.decline)
        decline.setAccessibilityLabel("Not now")
        whisper.addArrangedSubview(decline)
        let notNow = NSTextField(labelWithString: "Not now")
        notNow.font = BarTheme.stubDetailFont
        notNow.textColor = BarTheme.secondaryColor
        whisper.addArrangedSubview(notNow)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            voice.topAnchor.constraint(equalTo: card.topAnchor, constant: 12 - inset),
            voice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            voice.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -textInset),
            row.topAnchor.constraint(equalTo: voice.bottomAnchor, constant: 9),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: BarTheme.rowHeight),
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            whisper.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            whisper.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            whisper.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -textInset),
            whisper.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -3),
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
