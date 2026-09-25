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
        // The product: menu-bar app, hotkeys, searcher, graph, breaths.
        .executableTarget(name: "lodestar", dependencies: [
            "LodestarCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "OrderedCollections", package: "swift-collections"),
        ]),
        // Slice 0: the window-identity probe. Throwaway by design.
        .executableTarget(name: "probe", dependencies: ["LodestarCore"]),
        .testTarget(name: "LodestarCoreTests", dependencies: ["LodestarCore"],
                    // The editor's accuracy fixture, read by path.
                    exclude: ["Fixtures"]),
        // The scenario harness: the real engine, glass, and coach wired the
        // way the app wires them, driven by scripted keystrokes against a
        // world that never moves a window.
        .testTarget(name: "LodestarAppTests", dependencies: ["lodestar", "LodestarCore"]),
    ]
)
