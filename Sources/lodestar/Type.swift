import AppKit
import ObjectiveC

/// The type contract (design/02-type.md): one family, the system's sans,
/// on four sizes and three weights, except where you edit with vim: the
/// draft under Vim and the editor's lens are the system's mono. Every word
/// Lodestar draws is a role below; a surface names the role and never builds
/// a font.
///
/// A font cannot follow the look the way a colour does: it is a value, not
/// an appearance-aware object. So a view holds its *role*, and the font is
/// resolved from the role in the look of the view that draws it, again
/// whenever that look changes (`TypeBearing`).
extension BarTheme {
    /// What a piece of text is for. Size, weight and figures follow from it.
    enum Role: String, CaseIterable {
        /// What you type into a bar: the launcher, Ask, Commands.
        case field
        /// A sentence the product speaks.
        case voice
        /// A bar's name.
        case title
        /// A room's name at its head.
        case roomTitle
        /// What a row, a card or a note says.
        case body
        /// The coach's line and a stub's name: the voice at the body's size.
        case quietVoice
        /// The letters the hand has typed, shown back.
        case typed
        /// A word that must be found first, at the body's size.
        case emphasis
        /// A number at the title's size.
        case figure
        /// A number read across the screen.
        case largeFigure
        /// Captions, footers, details; the floor for text.
        case meta
        /// A name the eye lands on among captions.
        case name
        /// A setting's title, a tile's name, a search hit: a list of these is
        /// medium, so no row is the heaviest thing on the page.
        case label
        /// A popup's value, a button's title, a status word.
        case control
        /// A group's header.
        case heading
        /// A key's letter.
        case key
        /// The draft's text under Vim and the editor's lens: mono, where vim
        /// is. Under Standard the draft is set in the body.
        case draft
        /// The draft's lit letters.
        case draftMarked

        var size: CGFloat {
            switch self {
            case .field, .largeFigure: return Scale.input
            case .voice, .title, .roomTitle, .figure: return Scale.title
            case .body, .quietVoice, .typed, .emphasis, .label, .control, .draft, .draftMarked: return Scale.body
            case .meta, .name, .heading, .key: return Scale.meta
            }
        }

        /// The weight by day. At night it is one step heavier.
        var weight: NSFont.Weight {
            switch self {
            case .field, .voice, .title, .body, .quietVoice, .control, .meta, .draft: return .regular
            case .name, .label: return .medium
            case .roomTitle, .typed, .emphasis, .figure, .largeFigure, .heading, .key, .draftMarked: return .semibold
            }
        }

        /// Whether the role is a number that changes in place, so its
        /// digits hold their width. Any other role asks for it per use.
        var isFigure: Bool { self == .figure || self == .largeFigure }

        /// Mono is where vim is, and nowhere else: every letter of the draft
        /// and the editor's lens is one cell, and so is the block cursor.
        var isMono: Bool { self == .draft || self == .draftMarked }

        /// Light type on a dark ground reads thinner than the same weight
        /// dark on light, so night is one step up: regular to medium,
        /// medium to semibold, semibold to bold.
        static func heavier(_ weight: NSFont.Weight) -> NSFont.Weight {
            switch weight {
            case .regular: return .medium
            case .medium: return .semibold
            case .semibold: return .bold
            default: return weight
            }
        }

        func weight(night: Bool) -> NSFont.Weight { night ? Self.heavier(weight) : weight }

        /// The role's font. `tabular` keeps the digits one width, for a
        /// number that changes in place; a figure role always does.
        func font(night: Bool, tabular: Bool = false) -> NSFont {
            let weight = weight(night: night)
            if isMono { return NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
            return tabular || isFigure
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
        }

        /// The font in the look an appearance is.
        func font(in appearance: NSAppearance, tabular: Bool = false) -> NSFont {
            font(night: BarTheme.isNight(appearance), tabular: tabular)
        }

        /// The font in the look the Mac is in: for a measure, or for text
        /// drawn into an attributed string that a view will restyle.
        var font: NSFont { font(night: Tone.systemDark) }
        var tabularFont: NSFont { font(night: Tone.systemDark, tabular: true) }
    }

    static func isNight(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// A role as a view holds it.
    struct Style: Equatable {
        let role: Role
        let tabular: Bool
        func font(in appearance: NSAppearance) -> NSFont { role.font(in: appearance, tabular: tabular) }
    }

    /// The attributes that make a run of an attributed string a role: its
    /// font now, and the style a view re-resolves it from when the look
    /// changes.
    static func attributes(_ role: Role, tabular: Bool = false, color: NSColor? = nil,
                           in appearance: NSAppearance? = nil) -> [NSAttributedString.Key: Any] {
        let night = appearance.map(isNight) ?? Tone.systemDark
        var out: [NSAttributedString.Key: Any] = [
            .font: role.font(night: night, tabular: tabular),
            .lodestarStyle: Style(role: role, tabular: tabular),
        ]
        if let color { out[.foregroundColor] = color }
        return out
    }

    /// The width of a text in a role, in whole points. A sans is rarely a
    /// whole number wide, and a container sized to its text that does not
    /// round up truncates the text by a fraction of a point.
    static func width(of text: String, in role: Role, tabular: Bool = false, night: Bool = Tone.systemDark) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: role.font(night: night, tabular: tabular)]).width)
    }

    /// The width of a space in a role: what a block cursor covers where
    /// there is no letter, at the end of a line.
    static func spaceWidth(in role: Role) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: role.font]).width
    }
}

extension NSAttributedString.Key {
    /// The role a run of text was set in, for a view to resolve again.
    static let lodestarStyle = NSAttributedString.Key("LodestarTypeStyle")
}

// MARK: - A view that holds a role

/// A view that draws text in a font: a field, a button, a text view. It
/// holds the role, sets the font from it in its own look, and sets it
/// again when that look changes, so a surface on screen when the Mac turns
/// dark takes night's weight without being built again.
protocol TypeBearing: NSView {
    var font: NSFont? { get set }
    /// Any attributed text the view holds, in a form it can be given back.
    func restyleAttributedText(_ restyle: (NSAttributedString) -> NSAttributedString?)
}

extension NSControl: TypeBearing {
    func restyleAttributedText(_ restyle: (NSAttributedString) -> NSAttributedString?) {
        if let text = restyle(attributedStringValue) { attributedStringValue = text }
        if let field = self as? NSTextField,
           let placeholder = field.placeholderAttributedString, let text = restyle(placeholder) {
            field.placeholderAttributedString = text
        }
        if let button = self as? NSButton, let text = restyle(button.attributedTitle) {
            button.attributedTitle = text
        }
        // A popup's items are its menu's: their titles are attributed too.
        for item in menu?.items ?? [] {
            if let title = item.attributedTitle, let text = restyle(title) { item.attributedTitle = text }
        }
    }
}

extension NSTextView: TypeBearing {
    func restyleAttributedText(_ restyle: (NSAttributedString) -> NSAttributedString?) {
        guard let storage = textStorage, storage.length > 0, let text = restyle(storage) else { return }
        storage.setAttributedString(text)
    }
}

private final class TypeFollow {
    var style: BarTheme.Style?
    var observation: NSKeyValueObservation?
}

private var typeFollowKey = 0

extension TypeBearing {
    private var follow: TypeFollow {
        if let existing = objc_getAssociatedObject(self, &typeFollowKey) as? TypeFollow { return existing }
        let made = TypeFollow()
        objc_setAssociatedObject(self, &typeFollowKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    /// The role this view's font is resolved from, if it holds one.
    var typeStyle: BarTheme.Style? { follow.style }

    /// Set the view's font to a role, now and in every look it takes. The
    /// digits hold their width where `tabular`: a number that changes in
    /// place.
    func setRole(_ role: BarTheme.Role, tabular: Bool = false) {
        follow.style = BarTheme.Style(role: role, tabular: tabular)
        followLook()
        applyLook()
    }

    /// Resolve again when the look changes. Called by whatever sets
    /// attributed text made of roles; `setRole` does it itself.
    func followLook() {
        let follow = follow
        guard follow.observation == nil else { return }
        follow.observation = (self as NSView).observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            self?.applyLook()
        }
    }

    /// Set every role this view holds in the look it is in.
    func applyLook() {
        let appearance = effectiveAppearance
        if let style = follow.style {
            let font = style.font(in: appearance)
            if self.font != font { self.font = font }
        }
        restyleAttributedText { text in
            var changed = false
            let out = NSMutableAttributedString(attributedString: text)
            text.enumerateAttribute(.lodestarStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let style = value as? BarTheme.Style else { return }
                let font = style.font(in: appearance)
                if (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) != font {
                    out.addAttribute(.font, value: font, range: range)
                    changed = true
                }
            }
            return changed ? out : nil
        }
    }
}
