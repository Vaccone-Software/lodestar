import Foundation
import LodestarCore

/// The other end of the socket: a pipe, and deliberately nothing more.
///
/// It does not parse the verb, validate it, or know which verbs exist. All
/// of that lives in the running instance, so adding a verb is one change in
/// one place and an older `lodestar` binary in someone's `$PATH` cannot
/// disagree with the app about what a word means.
enum ControlClient {
    /// The words that mean "hand this to the running app". Kept here rather
    /// than inferred, so a typo becomes usage rather than a socket round
    /// trip that fails with something less helpful.
    static let verbs: Set<String> = ["go", "web", "layout", "breath", "state", "draft", "transcribe"]

    static func run(_ arguments: [String]) -> Never {
        let wantsJSON = arguments.contains("--json")
        let verb = arguments.filter { $0 != "--json" }
        // Hearing a file may first load dictation's ear (seconds; Parakeet's
        // first load on a Mac compiles it, about thirty): it is given longer.
        let timeout = verb.first == "transcribe" ? 90 : 15
        guard let reply = ControlSocket.ask(verb, timeout: timeout) else {
            FileHandle.standardError.write(Data(
                "✕ lodestar is not running — start it and try again\n".utf8))
            exit(69) // EX_UNAVAILABLE
        }
        let ok = reply["ok"] as? Bool ?? false
        // A message when there is one and JSON was not asked for; otherwise
        // the whole answer, because `state` is all result and no sentence.
        if !wantsJSON, let message = reply["message"] as? String ?? reply["error"] as? String {
            let line = ok ? message : "✕ \(message)"
            let handle = ok ? FileHandle.standardOutput : FileHandle.standardError
            handle.write(Data((line + "\n").utf8))
        } else if let data = try? JSONSerialization.data(
            withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(ok ? 0 : 1)
    }

}
