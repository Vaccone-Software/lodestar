import Foundation

/// A note from the Send Feedback window, on its way to the person who makes
/// Lodestar. It travels to the site's own endpoint, which forwards it by
/// email; the address it arrives at lives in the site's environment and
/// nowhere in the app, so nothing here can leak it.
///
/// Pure: what is sent, whether it may be, and the request that carries it.
/// The window and the network live in the app.
public struct Feedback: Equatable {
    /// The site's door for notes. The header is not a secret, only proof of
    /// origin: a form or a crawler posting without it is turned away.
    public static let endpoint = URL(string: "https://lodestar.vaccone.software/api/feedback")!
    public static let originHeader = ("x-lodestar-feedback", "1")

    /// The endpoint's own limits, kept here so the window refuses what the
    /// endpoint would silently cut.
    public static let messageLimit = 10_000
    public static let diagnosticsLimit = 60_000

    public var message: String
    /// Where a reply can go, when they want one. Optional on purpose: a
    /// note needs no identity.
    public var replyTo: String
    public var version: String
    public var macos: String
    /// The diagnostic report, only when they chose to include it.
    public var diagnostics: String?

    public init(message: String, replyTo: String = "", version: String = Lodestar.version,
                macos: String = Feedback.macosVersion, diagnostics: String? = nil) {
        self.message = message
        self.replyTo = replyTo
        self.version = version
        self.macos = macos
        self.diagnostics = diagnostics
    }

    public static var macosVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Why the note cannot go yet, in the window's words, or nil when it can.
    public enum Problem: Equatable {
        case empty
        case tooLong
        case replyAddress

        public var sentence: String {
            switch self {
            case .empty: return "Write a few words first."
            case .tooLong: return "That is longer than a note can be. Trim it a little."
            case .replyAddress: return "That reply address does not look like an email address."
            }
        }
    }

    public var problem: Problem? {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return .empty }
        if body.count > Self.messageLimit { return .tooLong }
        let reply = replyTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty, !Self.looksLikeAddress(reply) { return .replyAddress }
        return nil
    }

    /// The endpoint's test, exactly: something, an at sign, something with
    /// a dot in it, and no spaces. Anything stricter refuses real addresses.
    public static func looksLikeAddress(_ text: String) -> Bool {
        text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    /// The body the endpoint reads. An empty reply address and an absent
    /// report are left out rather than sent empty.
    public var payload: Data {
        var object: [String: String] = [
            "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
            "version": version,
            "macos": macos,
        ]
        let reply = replyTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty { object["replyTo"] = reply }
        if let diagnostics, !diagnostics.isEmpty {
            // The tail is the part worth keeping: the log's newest lines
            // are at the end of the report.
            object["diagnostics"] = String(diagnostics.suffix(Self.diagnosticsLimit))
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public func request(to endpoint: URL = Feedback.endpoint) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.originHeader.1, forHTTPHeaderField: Self.originHeader.0)
        request.httpBody = payload
        return request
    }

    /// What lands on the clipboard when the note cannot be sent, so nothing
    /// written is lost: the note itself, then where it came from.
    public var clipboardCopy: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n(Lodestar \(version), macOS \(macos))"
    }
}
