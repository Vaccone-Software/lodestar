// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "lodestar",
    platforms: [
        // 27 for Stoic, the robustness layer (deadlines, retry, atomic
        // files, locks, HTTP, the outbox); MLX alone would allow 14.
        .macOS("27.0")
    ],
    // The one exception to zero dependencies: Apple's MLX, which runs the
    // editor's language model on the GPU, and the tokenizer and loader its
    // Swift layer is built against (linked by the models service alone).
    // Everything Lodestar is, it still owns.
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.31.3")),
        // The same MLX the editor's package is built on, named so the
        // dictation ears can use its arrays and layers directly.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Held below 1.4, which adopted Swift 6.4's borrowing iteration: built
        // by Xcode 27, it links runtime entry points only macOS 27 has
        // (swift_initBorrow), and 0.37.0 would not start on anything older.
        // The tokenizer and template packages that use it accept any 1.x.
        .package(url: "https://github.com/apple/swift-collections", "1.3.0"..<"1.4.0"),
        // Stoic: deadlines, bounded retry, atomic and locked files, crash-loop
        // detection, the HTTP client, the durable outbox a note waits in, and
        // StoicXPC, the one way the app calls its two bundled services
        // (their lifecycle, deadlines, retries by repeat safety, ending and
        // killing, idle exit and watchdog are decided there, once).
        // Ours (Vaccone Software).
        // The sealed records, clipboard and downloads need its Crypto trait
        // (swift-crypto, which is CryptoKit on Apple platforms).
        .package(url: "https://github.com/Vaccone-Software/stoic", .upToNextMinor(from: "0.5.0"), traits: ["Crypto"]),
    ],
    targets: [
        // The AX layer every slice builds on. Its one dependency is Stoic,
        // for the robustness its files, waits, retries and the feedback
        // note's trip to the site need.
        .target(name: "LodestarCore", dependencies: [
            .product(name: "Stoic", package: "stoic"),
            .product(name: "StoicFoundation", package: "stoic"),
            .product(name: "StoicStore", package: "stoic"),
            // The config file: StoicJSON parses it (with line and column),
            // StoicSettings holds it as a hand-edited store that never
            // writes over a file it cannot read, and StoicSchema's
            // Schema.json() types its tree. ConfigSchema stays the validator.
            .product(name: "StoicJSON", package: "stoic"),
            .product(name: "StoicSchema", package: "stoic"),
            .product(name: "StoicSettings", package: "stoic"),
            .product(name: "StoicHTTP", package: "stoic"),
            // The models and the update's zip: resumable, verified while they
            // stream, placed whole or not at all.
            .product(name: "StoicDownloads", package: "stoic"),
            .product(name: "StoicSealed", package: "stoic"),
            .product(name: "StoicSealedKeychain", package: "stoic"),
            .product(name: "StoicApple", package: "stoic"),
            // The models' and the reader's methods are declared here, once,
            // for the app and both services (design/25).
            .product(name: "StoicXPC", package: "stoic"),
        ], swiftSettings: [
            // Swift 6 language mode for Core alone: its data races are
            // compile errors. Every other target is still Swift 5 (see
            // swiftLanguageModes below) and moves when it is clean.
            .swiftLanguageMode(.v6),
        ]),
        // Dictation's settling ears: second recognizers that re-hear a
        // phrase. Parakeet runs here, on the Neural Engine (Core ML, a system
        // framework); Qwen3-ASR's files are named here and it runs on MLX,
        // in the models service (LodestarMLX).
        .target(name: "LodestarEars", dependencies: ["LodestarCore"]),
        // Everything that evaluates on MLX: the editor's and dictation's
        // language models and the Qwen3-ASR ear. Linked by the models
        // service and the probe, never by the app.
        .target(name: "LodestarMLX", dependencies: [
            "LodestarCore",
            "LodestarEars",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // The product: menu-bar app, hotkeys, searcher, graph, breaths. It
        // links no MLX: its models run in the models service, so its own
        // exit never runs one of MLX's destructors.
        .executableTarget(name: "lodestar", dependencies: [
            "LodestarCore",
            "LodestarEars",
            .product(name: "OrderedCollections", package: "swift-collections"),
            .product(name: "Stoic", package: "stoic"),
            .product(name: "StoicStore", package: "stoic"),
            .product(name: "StoicHTTP", package: "stoic"),
            .product(name: "StoicDownloads", package: "stoic"),
            .product(name: "StoicSealed", package: "stoic"),
            .product(name: "StoicApple", package: "stoic"),
            .product(name: "StoicXPC", package: "stoic"),
        ]),
        // The clipboard's reader: an XPC service the app carries in
        // Contents/XPCServices (scripts/make-app.sh assembles it), so a copy
        // whose read waits never waits on the app's main thread. An XPCHost.
        .executableTarget(name: "LodestarClipboardReader", dependencies: [
            "LodestarCore",
            .product(name: "StoicXPC", package: "stoic"),
        ]),
        // The models service: an XPC service the app carries in
        // Contents/XPCServices (scripts/make-app.sh assembles it, with MLX's
        // kernels in its own Resources), the one process that runs MLX. An
        // XPCHost.
        .executableTarget(name: "LodestarModels", dependencies: [
            "LodestarCore", "LodestarMLX",
            .product(name: "StoicXPC", package: "stoic"),
        ]),
        // Slice 0: the window-identity probe. Throwaway by design.
        .executableTarget(name: "probe", dependencies: ["LodestarCore", "LodestarEars", "LodestarMLX"]),
        // A stand-in app with plain windows, for the tests that move real
        // windows with Lodestar's own actions. Built beside the tests,
        // never shipped.
        .executableTarget(name: "WindowFixture", path: "Tests/WindowFixture"),
        .testTarget(name: "LodestarCoreTests", dependencies: [
                        "LodestarCore",
                        .product(name: "StoicTesting", package: "stoic"),
                        .product(name: "StoicHTTP", package: "stoic"),
                        .product(name: "StoicDownloads", package: "stoic"),
                        .product(name: "StoicJSON", package: "stoic"),
                        .product(name: "StoicSettings", package: "stoic"),
                        .product(name: "StoicSealed", package: "stoic"),
                        .product(name: "StoicSealedKeychain", package: "stoic"),
                        .product(name: "StoicStore", package: "stoic"),
                        .product(name: "StoicApple", package: "stoic"),
                    ],
                    // The editor's accuracy fixture, read by path.
                    exclude: ["Fixtures"],
                    // For the leak guard's constructor (Overrides.swift).
                    swiftSettings: [.enableExperimentalFeature("SymbolLinkageMarkers")]),
        // The scenario harness: the real engine, glass, and coach wired the
        // way the app wires them, driven by scripted keystrokes against a
        // world that never moves a window.
        .testTarget(name: "LodestarAppTests", dependencies: [
            "lodestar", "LodestarCore",
            // The MLX code the models service runs, tested where it lives.
            "LodestarMLX",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "StoicTesting", package: "stoic"),
            .product(name: "StoicHTTP", package: "stoic"),
            .product(name: "StoicDownloads", package: "stoic"),
            .product(name: "StoicSealed", package: "stoic"),
            .product(name: "StoicStore", package: "stoic"),
            // XPCSimulatedService: the real host in this process, on a TestClock.
            .product(name: "StoicXPC", package: "stoic"),
        ], swiftSettings: [.enableExperimentalFeature("SymbolLinkageMarkers")]),
    ],
    // Tools 6.1 for the Crypto trait; the code stays in Swift 5 mode, as it
    // was under tools 5.9, except LodestarCore (its own swiftSettings).
    swiftLanguageModes: [.v5]
)
