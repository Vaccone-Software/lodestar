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

/// An edit of the config that did not happen, in Lodestar's words. What is
/// the person's to fix (a line and column that does not parse, a value the
/// schema refuses) is said. What is the disk's or another process's (the
/// store's own error, a lock wait) is not: it goes to the log, whole, under
/// the reference `FailureWords` draws (`FailureWords.sentence(forEdit:)`).
extension Config.EditError: Presentable {
    public var presentation: Presentation {
        switch self {
        case .unreadable(let file):
            Presentation(
                Wording("lodestar.config.unreadable", default: "Lodestar could not read {file}.",
                        arguments: ["file": .text(file)]),
                recovery: .tryAgain)
        case .unparsed(let detail):
            Presentation(
                Wording("lodestar.config.unparsed", default: "The config has a problem at {detail}. Fix it, then try again.",
                        arguments: ["detail": .text(detail)]),
                recovery: .nothing)
        case .invalid(let detail):
            Presentation(
                Wording("lodestar.config.invalid", default: "That would make the config invalid: {detail}.",
                        arguments: ["detail": .text(detail)]),
                recovery: .changeInput(fields: []))
        case .newer:
            Presentation(
                Wording("lodestar.config.newer", default: "A newer Lodestar wrote the config."),
                recovery: .updateApp)
        case .busy:
            Presentation(
                Wording("lodestar.config.busy", default: "Another copy of Lodestar is saving the config."),
                recovery: .wait(until: nil))
        case .storage:
            Presentation(
                Wording("lodestar.config.write", default: "Lodestar could not save the config."),
                recovery: .tryAgain)
        }
    }
}

/// A lode edit from ⌘K that could not happen. Every case is the person's own
/// path, said as they typed it.
extension GraphJsonEditor.EditError: Presentable {
    public var presentation: Presentation {
        switch self {
        case .blockedByLeaf(let path):
            Presentation(
                Wording("lodestar.graph.leaf", default: "lode {path} is already a destination.",
                        arguments: ["path": .text(path)]),
                recovery: .nothing)
        case .taken(let path):
            Presentation(
                Wording("lodestar.graph.taken", default: "lode {path} is already bound.",
                        arguments: ["path": .text(path)]),
                recovery: .nothing)
        case .missing(let path):
            Presentation(
                Wording("lodestar.graph.missing", default: "lode {path} is not in the config.",
                        arguments: ["path": .text(path)]),
                recovery: .nothing)
        }
    }
}

/// A web link or route from ⌘K that could not happen, in the words the web
/// bar's own checks use.
extension WebJsonEditor.EditError: Presentable {
    public var presentation: Presentation {
        switch self {
        case .emptyName:
            Presentation(Wording("lodestar.web.empty-name", default: "A link needs a name."), recovery: .nothing)
        case .emptyPattern:
            Presentation(Wording("lodestar.web.empty-pattern", default: "A route needs a pattern."), recovery: .nothing)
        case .taken(let name, let target):
            Presentation(
                Wording("lodestar.web.taken", default: "{name} is already {target}.",
                        arguments: ["name": .text(name), "target": .text(target)]),
                recovery: .nothing)
        case .missing(let name):
            Presentation(
                Wording("lodestar.web.missing", default: "{name} is not in the config.",
                        arguments: ["name": .text(name)]),
                recovery: .nothing)
        case .blocked(let path):
            Presentation(
                Wording("lodestar.web.blocked", default: "{path} in the config is not a section.",
                        arguments: ["path": .text(path)]),
                recovery: .nothing)
        case .noProfile:
            Presentation(Wording("lodestar.web.no-profile", default: "Pick a profile. A route has to name one."),
                         recovery: .nothing)
        }
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
        return words(of: presented)
    }

    /// The sentence for an edit of the config that did not happen.
    ///
    /// What the disk or another process did is logged whole. An edit refused
    /// for what it says (a name that is taken, a value the schema refuses, a
    /// file that does not parse) is said to the person and is not in the log:
    /// the words hold what they typed or what their file says, which can be a
    /// link or a host, and the log is made to be pasted. The log has the
    /// reference and which refusal it was.
    public static func sentence(forEdit error: any Error, doing: String) -> String {
        switch error {
        case let error as Config.EditError:
            switch error {
            case .unreadable, .busy, .storage: sentence(for: error, doing: doing)
            case .unparsed, .invalid, .newer: refusal(error, doing: doing)
            }
        case let error as GraphJsonEditor.EditError: refusal(error, doing: doing)
        case let error as WebJsonEditor.EditError: refusal(error, doing: doing)
        default: sentence(for: ConfigWriteFailure(underlying: error), doing: doing)
        }
    }

    private static func refusal(_ error: any Presentable, doing: String) -> String {
        guard let presented = error.presented() else { return sentence(for: error, doing: doing) }
        Log.info(doing, ["reference": presented.reference.description, "refused": presented.message.key])
        return words(of: presented)
    }

    private static func words(of presented: Presented) -> String {
        [String(localized: presented.message), recovery(presented.recovery)]
            .filter { !$0.isEmpty }.joined(separator: " ")
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
