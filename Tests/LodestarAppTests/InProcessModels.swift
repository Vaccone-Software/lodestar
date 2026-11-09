import Foundation
import LodestarCore
import LodestarMLX
@testable import lodestar

/// The live tests' models, loaded in the test's own process. The app asks
/// MLX only through its models service, which a test bundle does not carry,
/// so a test that runs a real model (set by an environment variable, never
/// by default) loads it here with the code the service runs.
enum InProcessModels {
    struct Backend: EditorBackend {
        let model: MLXLanguageModel
        func respond(to sentence: String, instructions: String) async throws -> String {
            try await model.respond(to: sentence, instructions: instructions)
        }
        func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String {
            try await model.rewrite(text, prompt: prompt)
        }
        func warm(_ prompt: IntentPass.Prompt) async throws {
            try await model.warm(prompt)
        }
    }

    static func load(directory: URL, label: String, context: [String: Bool]) async throws -> any EditorBackend {
        Backend(model: try await MLXLanguageModels.load(LanguageModelSpec(directory: directory.path, label: label,
                                                                          context: context)))
    }

    static let editor: EditorModel.Loader = { engine in
        guard let directory = EditorModels.directory(for: engine) else { throw EditorModelError.missing(engine) }
        return try await load(directory: directory, label: engine.rawValue, context: engine.additionalContext)
    }

    static let cleanup: DraftModel.Loader = { model in
        guard let directory = EditorModels.directory(for: model.manifest) else {
            throw EditorModelError.unavailable("\(model.name) is not on this Mac")
        }
        return try await load(directory: directory, label: model.rawValue, context: model.additionalContext)
    }
}
