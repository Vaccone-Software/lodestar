import Foundation
import LodestarCore

extension Draft.Buffer {
    /// The text just before `point` changed as the settler decided: a
    /// period dropped or added after the last non-space character.
    /// Returns how many characters `point` moved by.
    mutating func applyBefore(_ change: Draft.Settler.Landing.Before, at point: Int) -> Int {
        guard change != .unchanged else { return 0 }
        var end = point
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        guard end > 0 else { return 0 }
        switch change {
        case .dropPeriod:
            guard characters[end - 1] == "." else { return 0 }
            replace((end - 1)..<end, with: "")
            return -1
        case .addPeriod:
            replace(end..<end, with: ".")
            return 1
        case .unchanged:
            return 0
        }
    }
}

/// A draft that esc has closed and that is still waiting, out of sight,
/// for the last words.
///
/// The panel goes at once; what the clipboard keeps should not lose the
/// last second of speech to a hurry. The draft's text is copied here, as
/// it stood, and the finals the stop drains are placed into the copy the
/// way they would have been in the draft, through a copy of its settler.
/// Nothing in it touches the controller's own state, so a draft opened
/// again meanwhile is not disturbed by it.
final class Departure {
    private(set) var buffer: Draft.Buffer
    private var settler: Draft.Settler
    /// Words reserved when the hand began writing, and the page they
    /// were reserved on, as in the draft.
    private var provisional: (range: Range<Int>, text: String, base: [Character])?
    /// Where words said before the hand cut in belong, if the draft was
    /// holding the place.
    private var anchor: Int?

    init(buffer: Draft.Buffer, settler: Draft.Settler,
         provisional: (range: Range<Int>, text: String, base: [Character])?, anchor: Int?) {
        self.buffer = buffer
        self.settler = settler
        self.provisional = provisional
        self.anchor = anchor
    }

    /// What the clipboard is given: the text, and the words still being
    /// heard at its end as the draft would have shown them.
    var text: String {
        buffer.text + (buffer.ghost.isEmpty ? "" : Draft.separator(after: buffer.characters, before: buffer.ghost) + buffer.ghost)
    }

    /// One final the stop drained.
    func take(_ heard: Heard) {
        buffer.clearGhost()
        if let standing = provisional {
            provisional = nil
            if buffer.slice(standing.range) == standing.text {
                // Words settled early: the final replaces them in place.
                let landing = settler.land(heard, after: buffer.slice(max(0, standing.range.lowerBound - 200)..<standing.range.lowerBound),
                                           canReachBack: false)
                let shift = buffer.applyBefore(landing.before, at: standing.range.lowerBound)
                let range = (standing.range.lowerBound + shift)..<(standing.range.upperBound + shift)
                let lead = Draft.separator(after: buffer.characters[..<range.lowerBound], before: landing.text)
                buffer.replace(range, with: lead + landing.text)
            } else if let rest = Draft.Reserved.remainder(of: heard, after: standing.text) {
                // Edited since: what follows them lands after the edit.
                land(rest, at: Draft.Reserved.end(of: standing.range, was: standing.base, now: buffer.characters))
            }
            return
        }
        let at = min(anchor ?? buffer.cursor, buffer.count)
        anchor = nil
        land(heard, at: at)
    }

    private func land(_ heard: Heard, at point: Int) {
        let landing = settler.land(heard, after: buffer.slice(max(0, point - 200)..<point), canReachBack: false)
        let at = point + buffer.applyBefore(landing.before, at: point)
        let lead = Draft.separator(after: buffer.characters[..<at], before: landing.text)
        let replacement = lead + landing.text
        buffer.replace(at..<at, with: replacement)
        buffer.setCursor(at + replacement.count)
    }
}
