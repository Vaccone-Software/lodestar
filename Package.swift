// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lodestar",
    platforms: [
        // 14 for MLX, the editor's runtime.
        .macOS(.v14)
    ],
    // The one exception to zero dependencies: Apple's MLX, which runs the
    // editor's language model on the GPU, and the tokenizer and loader its
    // Swift layer is built against. Everything Lodestar is, it still owns.
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
    ],
    targets: [
        // The AX layer every slice builds on. No dependencies, by design.
        .target(name: "LodestarCore"),
        // Dictation's settling ears: second recognizers that re-hear a
        // phrase, on MLX (Qwen3-ASR) or the Neural Engine (Parakeet, Core
        // ML, a system framework).
        .target(name: "LodestarEars", dependencies: [
            "LodestarCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // The product: menu-bar app, hotkeys, searcher, graph, breaths.
        .executableTarget(name: "lodestar", dependencies: [
            "LodestarCore",
            "LodestarEars",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "OrderedCollections", package: "swift-collections"),
        ]),
        // Slice 0: the window-identity probe. Throwaway by design.
        .executableTarget(name: "probe", dependencies: ["LodestarCore", "LodestarEars"]),
        // A stand-in app with plain windows, for the tests that move real
        // windows with Lodestar's own actions. Built beside the tests,
        // never shipped.
        .executableTarget(name: "WindowFixture", path: "Tests/WindowFixture"),
        .testTarget(name: "LodestarCoreTests", dependencies: ["LodestarCore"],
                    // The editor's accuracy fixture, read by path.
                    exclude: ["Fixtures"]),
        // The scenario harness: the real engine, glass, and coach wired the
        // way the app wires them, driven by scripted keystrokes against a
        // world that never moves a window.
        .testTarget(name: "LodestarAppTests", dependencies: ["lodestar", "LodestarCore"]),
    ]
)
