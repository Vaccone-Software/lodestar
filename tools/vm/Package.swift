// swift-tools-version:6.0
// The test machine: macOS in a virtual machine of our own, on Apple's
// Virtualization framework, so a suite that needs a screen and the keys
// never takes the person's. A package of its own, outside Lodestar's: the
// app neither links it nor knows it exists.
import PackageDescription

let package = Package(
    name: "lodestar-vm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "lodestar-vm", path: "Sources/lodestar-vm"),
    ]
)
