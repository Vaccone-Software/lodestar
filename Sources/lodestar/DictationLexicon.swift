import Foundation
import LodestarCore

/// What dictation knows about how words sound and which are everyday
/// ones: the pronunciation dictionary and the frequency list the app
/// ships, read once, off the main thread, the first time a matcher is
/// built.
enum DictationLexicon {
    /// A pronouncer given instead of the bundled one: the stage's, read
    /// from the repository.
    nonisolated(unsafe) static var given: Pronouncer?
    static var pronouncer: Pronouncer { given ?? bundled }

    private static let bundled: Pronouncer = {
        CommonWords.frequentListURL = Bundle.main.url(forResource: "common-words", withExtension: "txt")
        guard let url = Bundle.main.url(forResource: "cmudict", withExtension: "dict"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Log.info("draft", ["pronunciations": "missing, spelling rules only"])
            return Pronouncer()
        }
        let pronouncer = Pronouncer(cmu: text)
        CommonWords.warm()
        Log.info("draft", ["pronunciations": pronouncer.wordCount])
        return pronouncer
    }()
}
