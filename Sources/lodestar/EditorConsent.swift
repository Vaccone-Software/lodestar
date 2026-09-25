import AppKit
import LodestarCore

/// The editor asks before it reads anything. Turning it on puts one card
/// on the glass: what it does, what it holds, and Accept or Decline, by
/// lode lode and lode ⌫ or by the mouse. Accepted once per Mac; declined,
/// the switch goes back off and nothing was read.
///
/// The card must be the one showing for a gesture to answer it: a card
/// another surface replaced is not a question anyone saw, so it is asked
/// again the next time the editor is turned on or Lodestar starts.
final class EditorConsent {
    static let tag = "editor-consent"
    static let sentence = "The editor reads what you write in every app to mark mistakes. "
        + "Your text stays on this Mac and is never kept"

    /// The card, drawn: sentence, the engine's line, the two answers.
    var present: (_ sentence: String, _ detail: String, _ rows: [GuideRow]) -> Void = { _, _, _ in }
    /// Is this card the one on the glass right now?
    var isShowing: () -> Bool = { false }
    var clear: () -> Void = {}
    /// Accepted: remembered for this Mac, and the editor starts.
    var accepted: () -> Void = {}
    /// Declined: the switch goes back off.
    var declined: () -> Void = {}

    func ask(detail: String) {
        present(Self.sentence, detail, [
            GuideRow(keys: ["lode", "lode"], label: "Accept", action: { [weak self] in _ = self?.assent() }),
            GuideRow(keys: ["lode", "⌫"], label: "Decline", action: { [weak self] in _ = self?.dismiss() }),
        ])
    }

    func assent() -> Bool {
        guard isShowing() else { return false }
        clear()
        accepted()
        return true
    }

    func dismiss() -> Bool {
        guard isShowing() else { return false }
        clear()
        declined()
        return true
    }

    /// The switch went off before an answer: the question goes with it.
    func withdraw() {
        if isShowing() { clear() }
    }
}
