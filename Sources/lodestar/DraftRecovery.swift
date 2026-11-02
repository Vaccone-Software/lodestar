import Foundation
import LodestarCore

/// What a launch does with the words a draft left in flight.
///
/// A clean close always clears the stash, so whatever is there at launch
/// is a draft that was cut off, whether by a crash, a SIGKILL, a power
/// loss or a logout, and none of those is told apart by the run marker.
/// It is kept as a card in the clipboard history when the history can take
/// one, so the pasteboard keeps what the hand copied last; otherwise it is
/// put on the pasteboard, as before.
enum DraftRecovery {
    static func restore(_ stranded: String,
                        keepCard: (String) -> Bool,
                        pasteboard: (String) -> Void,
                        flash: (String) -> Void) {
        if keepCard(stranded) {
            flash("⌂ Your draft is in the clipboard history")
        } else {
            pasteboard(stranded)
            flash("⌂ Your draft is on the clipboard")
        }
        Log.info("draft", ["recovered": stranded.count])
    }
}
