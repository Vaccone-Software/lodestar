import Foundation
import Stoic
import StoicXPC

// Lodestar's models service: every evaluation on MLX (the editor's language
// model, dictation's model for what was meant, the Qwen3-ASR ear) runs in an
// XPC service the app carries in Contents/XPCServices, the way Apple keeps
// work an app cannot afford to share its process with out of it. Measured in
// the app's own record before the move: a generation that never ended
// refused every question until the app restarted (42 times, once for 50
// minutes); the app's footprint reached 28.3 GB, 23.4 of it MLX's; and a
// quit crashed with MLX's destructors racing a compile on another thread.
// A service can be ended and started again, its memory goes with it, and
// launchd ends it without running a destructor in the app.
//
// The transport is StoicXPC (design/25): this file declares the service's
// methods once, for the app and the service both, and the wire types they
// carry. What a method is (how often it may be sent again, how long it may
// take, what a request left unanswered means) is said here and decided by
// the library, in the app (`XPCPeer`) and in the service (`XPCHost`).
//
// launchd starts the service at the first message and may end it at any
// moment, so the app keeps nothing in it that it could not send again: a
// model is loaded by its folder, and a request for a handle the service no
// longer holds answers `notLoaded`, which tells the app to load again.

public enum Models {
    /// The service's bundle identifier, in `Contents/XPCServices`.
    public static let serviceName = "com.vaccone.lodestar.models"

    /// A service that holds nothing and is asked nothing for this long ends
    /// itself: every page MLX and Metal held goes with the process, which
    /// letting a model go cannot promise, and launchd starts it again at the
    /// next load.
    public static let idleExit: Duration = .seconds(10)

    /// 16 kHz samples as their bytes, and back. Bulk data crosses as `Data`
    /// (design/25, rule 4): half a million samples are 518 ms through XPC's
    /// `Codable` encoding of an array and 0.37 ms as bytes.
    public static func bytes(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func samples(_ bytes: Data) -> [Float] {
        bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - The methods

extension Backend {
    /// The models' work: one evaluation at a time, because a second only
    /// competes with the first for the one GPU (and the service's own MLX
    /// lane lets one through at a time anyway).
    public static let models = Backend.compute("models")

    /// What asks about the service or lets go of what it holds: never
    /// behind a generation, so a status line or a release does not wait for
    /// the model to finish.
    public static let modelsControl = Backend.system("models.control")
}

/// The models service's methods, declared once for both sides.
///
/// Why each is what it is. A request that names a handle (a model, the ear)
/// can only be answered by the run that holds it: the handle goes with its
/// process, so sending it again to the next run could only answer
/// `notLoaded`. Those are `notRepeatable`, which also keeps a lost
/// generation from starting a service just to say so. They are `.long`:
/// the attempt is bounded by the caller's own deadline (the editor's eight
/// seconds, the ear's thirty), and a `.brief` attempt that is not
/// repeatable would finish shielded from its caller's cancellation, so a
/// deadline could not cancel the generation in the service.
///
/// `ifStuck` is what a generation that will not stop means: the service is
/// wedged in an evaluation that cancellation does not reach, and ending the
/// process is the only way it stops. The language models' twenty seconds
/// are the editor's (`ModelCalls.stuckAfter`) counted from the moment the
/// caller gave up; the ear's five are the grace a cooperative phrase needs
/// to notice its cancellation.
public enum ModelsAPI {
    /// How long a language model's request may stay unanswered after its
    /// caller left before the service is ended.
    public static let stuckAfter: Duration = .seconds(20)
    /// The same for the ear, which is only one phrase or one load.
    public static let earStuckAfter: Duration = .seconds(5)

    /// Loads a model by its folder: the handle. Twice leaves what once
    /// leaves (the service holds a second copy only when asked a second
    /// time, and a run lost under the first holds none), so a load lost with
    /// its service is sent once more to the next. It may take a minute.
    public static let loadLanguageModel = XPCMethod<LanguageModelSpec, String, ModelsFailure>(
        Backend.models.idempotent("loadLanguageModel", length: .long), ifStuck: .endService(after: stuckAfter))

    /// The sentence corrected. A generation does not repeat: it names a
    /// handle only this run holds.
    public static let respond = XPCMethod<ModelsGenerate, String, ModelsFailure>(
        Backend.models.notRepeatable("respond", length: .long), ifStuck: .endService(after: stuckAfter))

    /// The text as meant, by the same rule.
    public static let rewrite = XPCMethod<ModelsGenerate, String, ModelsFailure>(
        Backend.models.notRepeatable("rewrite", length: .long), ifStuck: .endService(after: stuckAfter))

    /// The prompt's beginning read once. It leaves the same cache however
    /// often it runs, but it too names a handle only this run holds, so it
    /// is not sent to another.
    public static let warm = XPCMethod<ModelsGenerate, XPCEmpty, ModelsFailure>(
        Backend.models.notRepeatable("warm", length: .long), ifStuck: .endService(after: stuckAfter))

    /// Lets a model go: twice is once, and a run that is gone holds nothing.
    public static let releaseLanguageModel = XPCMethod<String, XPCEmpty, Never>(
        Backend.modelsControl.idempotent("releaseLanguageModel"))

    /// Loads the ear by its folder. As a language model's load: repeatable,
    /// and a load that does not return ends the service.
    public static let loadEar = XPCMethod<EarSpec, XPCEmpty, ModelsFailure>(
        Backend.models.idempotent("loadEar", length: .long), ifStuck: .endService(after: earStuckAfter))

    /// One phrase heard. It names the ear this run holds: not repeatable.
    public static let transcribe = XPCMethod<EarTranscribe, Heard, ModelsFailure>(
        Backend.models.notRepeatable("transcribe", length: .long), ifStuck: .endService(after: earStuckAfter))

    public static let unloadEar = XPCMethod<XPCEmpty, XPCEmpty, Never>(
        Backend.modelsControl.idempotent("unloadEar"))

    /// `ModelsStats`, read from counters: never waits for the lane.
    public static let stats = XPCMethod<XPCEmpty, ModelsStats, Never>(
        Backend.modelsControl.readOnly("stats"))

    /// A small evaluation on the GPU: proof that the service started and
    /// MLX found its device and its kernels. It changes nothing; it waits
    /// for the lane and a cold device, so it is `.long`.
    public static let check = XPCMethod<XPCEmpty, ModelsCheck, ModelsFailure>(
        Backend.models.readOnly("check", length: .long))
}

// MARK: - What crosses

/// A language model by its folder: what a fresh service needs to load it.
public struct LanguageModelSpec: Codable, Sendable, Hashable {
    public var directory: String
    /// For the log.
    public var label: String
    /// The chat template's switches (Qwen's `enable_thinking`).
    public var context: [String: Bool]
    /// Reads each prompt's shared beginning once (off only for a bench).
    public var cachesInstructions: Bool

    public init(directory: String, label: String, context: [String: Bool] = [:], cachesInstructions: Bool = true) {
        self.directory = directory
        self.label = label
        self.context = context
        self.cachesInstructions = cachesInstructions
    }
}

/// One question to a loaded model. `respond` reads `prompt.instructions`
/// and no examples.
public struct ModelsGenerate: Codable, Sendable {
    public var handle: String
    public var text: String
    public var prompt: IntentPass.Prompt
    public init(handle: String, text: String, prompt: IntentPass.Prompt) {
        self.handle = handle
        self.text = text
        self.prompt = prompt
    }
}

/// The ear by its factory name and its folder.
public struct EarSpec: Codable, Sendable, Hashable {
    public var name: String
    public var directory: String
    public init(name: String, directory: String) {
        self.name = name
        self.directory = directory
    }
}

public struct EarTranscribe: Codable, Sendable {
    /// 16 kHz mono Float32, as `Models.bytes` writes it.
    public var samples: Data
    public var context: [String]
    public init(samples: Data, context: [String]) {
        self.samples = samples
        self.context = context
    }
}

/// Why a request has no answer, besides the ones the transport has
/// (`XPCCallError`).
public enum ModelsFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    /// The service holds no model under that handle (or no ear): it was
    /// started afresh since the load. Load again.
    case notLoaded
    /// Given up on while it ran: an ear load an unload overtook.
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .notLoaded: return "the models service holds no such model"
        case .cancelled: return "cancelled"
        case .failed(let why): return why
        }
    }
}

/// What the service holds, for the app's memory line.
public struct ModelsStats: Codable, Sendable, Equatable {
    public var pid: Int32
    public var footprintMB: Int
    /// What MLX holds, or nil before anything in this run touched MLX.
    public var mlxActiveMB: Int?
    public var mlxCacheMB: Int?
    public var languageModels: Int
    public var ear: Bool

    public init(pid: Int32, footprintMB: Int, mlxActiveMB: Int?, mlxCacheMB: Int?, languageModels: Int, ear: Bool) {
        self.pid = pid
        self.footprintMB = footprintMB
        self.mlxActiveMB = mlxActiveMB
        self.mlxCacheMB = mlxCacheMB
        self.languageModels = languageModels
        self.ear = ear
    }
}

public struct ModelsCheck: Codable, Sendable, Equatable {
    public var pid: Int32
    /// What the evaluation said, with the device it ran on.
    public var answer: String
    public init(pid: Int32, answer: String) {
        self.pid = pid
        self.answer = answer
    }
}

// MARK: - The engine the service drives

/// A language model the service loaded.
public protocol ServedLanguageModel: Sendable {
    func respond(to sentence: String, instructions: String) async throws -> String
    func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String
    func warm(_ prompt: IntentPass.Prompt) async throws
}

/// The ear the service loaded. It takes the MLX lane itself (`QwenEar`).
public protocol ServedEar: Sendable {
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard
    func unload()
}

/// What runs the models: MLX in the service (`MLXModelsEngine`), a fake in
/// the tests. Language-model work and `clearCache` and `check` are called
/// holding the lane.
public protocol ModelsEngine: Sendable {
    func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> any ServedLanguageModel
    func loadEar(_ spec: EarSpec) async throws -> any ServedEar
    func clearCache()
    /// MLX's active and cached memory in MB, or nil before MLX was touched.
    func memory() -> (activeMB: Int, cacheMB: Int)?
    func check() throws -> String
}
