import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A question about Settings in plain words, answered by Apple's on-device
/// model with the name of the row it means. Only where macOS 26 has
/// Apple Intelligence on: that model is the system's, loaded and released
/// by macOS, so asking costs no memory Lodestar holds. The answer is held
/// to the rows that exist (the model chooses among their names; it cannot
/// invent one), and it is a place to go, never a write: the row is lit and
/// the hand decides.
enum SettingsAsk {
    static var available: Bool { EditorEngine.appleIntelligence }

    static let instructions = """
        You help a person find one setting in the Mac app Lodestar. The list is grouped by \
        place, each place named with what it is about, and each setting is its place and \
        name, then what it does. Choose the one setting the request is about. \
        Examples: "make scrolling slower" is Scroll speed. "never save what I copy in my \
        password manager" is Excluded apps. "which microphone does dictation use" is \
        Microphone. "turn off the grammar checker" is Editor. If nothing fits, choose none.
        """

    static func answer(_ question: String, catalog: String, choices: [String],
                       completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task.detached {
                let reply = try? await pick(question, catalog: catalog, choices: choices)
                await MainActor.run { completion(reply == "none" ? nil : reply) }
            }
            return
        }
        #endif
        completion(nil)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func pick(_ question: String, catalog: String, choices: [String]) async throws -> String? {
        let session = LanguageModelSession(model: SystemLanguageModel.default,
                                           instructions: instructions + "\n\n" + catalog)
        let choice = DynamicGenerationSchema(name: "Choice", properties: [
            .init(name: "setting", schema: DynamicGenerationSchema(name: "Setting", anyOf: choices + ["none"])),
        ])
        let schema = try GenerationSchema(root: choice, dependencies: [])
        let response = try await session.respond(to: question, schema: schema,
                                                 options: GenerationOptions(temperature: 0))
        return try response.content.value(String.self, forProperty: "setting")
    }
    #endif
}
