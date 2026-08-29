// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lodestar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // The AX layer every slice builds on. No dependencies, by design.
        .target(name: "LodestarCore"),
        // The product: menu-bar app, hotkeys, searcher, graph, breaths.
        .executableTarget(name: "lodestar", dependencies: ["LodestarCore"]),
        // Slice 0: the window-identity probe. Throwaway by design.
        .executableTarget(name: "probe", dependencies: ["LodestarCore"]),
        .testTarget(name: "LodestarCoreTests", dependencies: ["LodestarCore"]),
        // The scenario harness: the real engine, glass, and coach wired the
        // way the app wires them, driven by scripted keystrokes against a
        // world that never moves a window.
        .testTarget(name: "LodestarAppTests", dependencies: ["lodestar", "LodestarCore"]),
    ]
)
