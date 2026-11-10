import Foundation
import Stoic
import StoicFoundation

/// The config could not be saved. Lodestar's words for it, since the error
/// underneath is Foundation's, whose text can hold a path with a person's name
/// in it and says nothing they can act on.
public struct ConfigWriteFailure: Error, Presentable {
    /// What the write threw. Goes to the log, never to a person.
    public let underlying: any Error

    public init(underlying: any Error) {
        self.underlying = underlying
    }

    public var presentation: Presentation {
        Presentation(
            Wording("lodestar.config.write", default: "Lodestar could not save the config."),
            recovery: .tryAgain)
    }
}

/// A failure as a person reads it: what happened and what to do. The
/// reference Stoic draws for it goes to the log with the whole error, not into
/// the sentence: these sentences are flashed for a moment, and nobody can copy
/// one there.
///
/// Stoic's `presented()` chooses the words (a `Presentable` error's own, the
/// ambient presenter's rule for a Foundation error, else a plain "Something
/// went wrong."). The error's own text never reaches the sentence: it goes to
/// the log, under the same reference.
public enum FailureWords {
    /// The sentence for `error`, and one log line with the whole of it.
    /// `doing` is the log's name for what was being attempted.
    public static func sentence(for error: any Error, doing: String) -> String {
        guard let presented = error.presented() else {
            Log.warning(doing, ["error": "\(error)", "presented": "nothing, it was cancelled"])
            return "Lodestar stopped before it finished."
        }
        Log.error(doing, ["reference": presented.reference.description, "error": "\(error)"])
        let parts = [String(localized: presented.message), recovery(presented.recovery)]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What the person can do, as a sentence of Lodestar's voice: plain, and
    /// without dashes or semicolons.
    static func recovery(_ recovery: Recovery) -> String {
        switch recovery {
        case .tryAgain: "Try again."
        case .wait: "Try again in a little while."
        case .signInAgain: "Sign in again."
        case .changeInput: "Check what you entered."
        case .checkFirst: "Check before you try again."
        case .updateApp: "Update Lodestar."
        case .contactSupport: "If it keeps happening, send feedback with the reference."
        case .nothing: ""
        }
    }
}
