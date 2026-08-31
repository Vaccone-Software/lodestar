import Foundation

/// What a script asked Lodestar to do.
///
/// Parsing lives here, pure, because the socket is the one door into this
/// app that no hand is behind. A gesture that misreads itself costs one
/// wrong window and a person who can see it happen; a verb that misreads
/// itself runs unattended, possibly in a loop, possibly at three in the
/// morning. So the grammar is a value, decided by a function with no world
/// around it, and tested at every edge rather than tried.
public enum ControlVerb: Equatable {
    /// Go somewhere: a graph chain if the letters resolve to one, an app
    /// name otherwise. Which it is cannot be decided here — that needs the
    /// graph — so both readings are carried and the caller picks.
    case go(query: [String], beside: Bool)
    case web(url: String, profile: String?)
    case layout(LayoutVerb)
    case breath(BreathVerb)
    /// What is on screen right now, as data. The one verb that changes
    /// nothing, and the only way to see the parked half of the world.
    case state
    /// Drive the draft the way the keys do: the doors, the two exits, the
    /// keys themselves, and an audio file in place of the microphone —
    /// the last is how a machine with no live mic tests dictation end to
    /// end against the shipped binary.
    case draft(DraftVerb)
}

public enum DraftVerb: Equatable {
    case open(Draft.Door)
    case close
    case commit
    case state
    case type(String)
    case key(String, shift: Bool)
    case audio(String)
}

public enum LayoutVerb: Equatable {
    case undo, redo, flip
    case fill(beside: Bool)
    case index(Int)
}

public enum BreathVerb: Equatable {
    case go([String])
    case save([String])
    case delete([String])
}

/// Why a verb could not be read. A type rather than a bare string because
/// `Result` wants an `Error`, and because the message crosses a socket to
/// a script that may be the only thing reading it.
public struct ControlError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum ControlParse {
    /// The largest digit `lode 1…9` can name, and so the largest a script
    /// may name either — the addresses are the same addresses.
    public static let maxIndex = 9

    public static func parse(_ arguments: [String]) -> Result<ControlVerb, ControlError> {
        var args = arguments
        guard let verb = args.first else { return .failure(ControlError("no verb")) }
        args.removeFirst()

        // Flags are pulled out first and everywhere, so `go --beside g` and
        // `go g --beside` are the same sentence. A script should not have to
        // remember an order that the shell does not enforce.
        let beside = args.contains("--beside")
        args.removeAll { $0 == "--beside" }

        switch verb {
        case "go":
            let query = args.filter { !$0.hasPrefix("--") }
            guard !query.isEmpty else { return .failure(ControlError("go needs a chain or an app name")) }
            if let unknown = args.first(where: { $0.hasPrefix("--") }) {
                return .failure(ControlError("unknown option \(unknown)"))
            }
            return .success(.go(query: query, beside: beside))

        case "web":
            var profile: String?
            if let flag = args.firstIndex(of: "--profile") {
                guard flag + 1 < args.count else { return .failure(ControlError("--profile needs a value")) }
                profile = args[flag + 1]
                args.removeSubrange(flag...(flag + 1))
            }
            guard let url = args.first(where: { !$0.hasPrefix("--") }) else {
                return .failure(ControlError("web needs a url"))
            }
            return .success(.web(url: url, profile: profile))

        case "layout":
            guard let which = args.first else {
                return .failure(ControlError("layout needs undo, redo, flip, fill, or index"))
            }
            switch which {
            case "undo": return .success(.layout(.undo))
            case "redo": return .success(.layout(.redo))
            case "flip": return .success(.layout(.flip))
            case "fill": return .success(.layout(.fill(beside: beside)))
            case "index":
                guard args.count > 1, let digit = Int(args[1]) else {
                    return .failure(ControlError("index needs a number 1…\(maxIndex)"))
                }
                guard digit >= 1, digit <= maxIndex else {
                    return .failure(ControlError("index must be 1…\(maxIndex)"))
                }
                return .success(.layout(.index(digit)))
            default: return .failure(ControlError("unknown layout verb '\(which)'"))
            }

        case "breath":
            guard let head = args.first else { return .failure(ControlError("breath needs an address")) }
            switch head {
            case "save", "delete":
                let rest = Array(args.dropFirst())
                guard let chain = address(rest) else {
                    return .failure(ControlError("breath \(head) needs an address"))
                }
                return .success(.breath(head == "save" ? .save(chain) : .delete(chain)))
            default:
                guard let chain = address(args) else {
                    return .failure(ControlError("breath needs an address"))
                }
                return .success(.breath(.go(chain)))
            }

        case "state":
            return .success(.state)

        case "draft":
            guard let head = args.first else {
                return .failure(ControlError("draft needs speak, edit, close, commit, state, type, key, or audio"))
            }
            let rest = Array(args.dropFirst())
            switch head {
            case "speak": return .success(.draft(.open(.speak)))
            case "edit": return .success(.draft(.open(.edit)))
            case "close": return .success(.draft(.close))
            case "commit": return .success(.draft(.commit))
            case "state": return .success(.draft(.state))
            case "type":
                guard !rest.isEmpty else { return .failure(ControlError("draft type needs text")) }
                return .success(.draft(.type(rest.joined(separator: " "))))
            case "key":
                let shift = rest.contains("--shift")
                guard let name = rest.first(where: { !$0.hasPrefix("--") }) else {
                    return .failure(ControlError("draft key needs a key name"))
                }
                return .success(.draft(.key(name, shift: shift)))
            case "audio":
                guard let path = rest.first else { return .failure(ControlError("draft audio needs a file")) }
                return .success(.draft(.audio(path)))
            default:
                return .failure(ControlError("unknown draft verb '\(head)'"))
            }

        default:
            return .failure(ControlError("unknown verb '\(verb)'"))
        }
    }

    /// An address written either way: `e p` or `ep`. Both are the same two
    /// presses, and a shell splits on spaces for reasons that have nothing
    /// to do with this grammar.
    public static func address(_ tokens: [String]) -> [String]? {
        let letters = tokens.filter { !$0.hasPrefix("--") }
            .flatMap { $0.map(String.init) }
            .map { $0.lowercased() }
        guard !letters.isEmpty else { return nil }
        return letters
    }
}
