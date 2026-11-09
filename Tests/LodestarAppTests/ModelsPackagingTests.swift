import Foundation
import XCTest
@testable import lodestar
import LodestarCore

/// The models service is packaged where the app looks for it, carries MLX's
/// kernels where MLX looks for them, is signed before the app, and is the
/// only process that links MLX. The signed bundle proves it starts and
/// evaluates (`SelfTest.modelsService`).
final class ModelsPackagingTests: XCTestCase {
    /// The service ships in the bundle under the name the app asks for,
    /// with MLX's kernels in its own Resources, is signed before the app,
    /// and is the only process that links MLX.
    func testTheServiceIsPackagedUnderTheNameTheAppAsksFor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("packaging/Models-Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, Models.serviceName)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "LodestarModels")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "XPC!")
        let service = try XCTUnwrap(plist["XPCService"] as? [String: Any])
        XCTAssertEqual(service["ServiceType"] as? String, "Application")
        XCTAssertEqual(service["RunLoopType"] as? String, "NSRunLoop")
        XCTAssertNil(service["JoinExistingSession"], "files and the GPU are not per-session resources")

        let makeApp = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        XCTAssertTrue(makeApp.contains("Contents/XPCServices/LodestarModels.xpc"))
        XCTAssertTrue(makeApp.contains("cp -R \"$bundle\" \"$MODELS/Contents/Resources/\""),
                      "MLX finds its kernels in the main bundle's Resources, and in a service that is the .xpc")
        for script in ["scripts/make-app.sh", "scripts/release.sh"] {
            let lines = try String(contentsOf: root.appendingPathComponent(script), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let signsService = lines.firstIndex { $0.contains("--sign") && ($0.contains("\"$MODELS\"") || $0.contains("LodestarModels.xpc\"")) }
            let signsApp = lines.firstIndex { $0.contains("--sign") && $0.hasSuffix("\"$APP\"") }
            let service = try XCTUnwrap(signsService, "\(script) signs the service")
            let app = try XCTUnwrap(signsApp, "\(script) signs the app")
            XCTAssertLessThan(service, app, "\(script): inside out, the service before the app")
            XCTAssertFalse(lines[service].contains("--entitlements"), "\(script): hardened runtime and nothing more")
        }

        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let app = try XCTUnwrap(package.range(of: ".executableTarget(name: \"lodestar\""))
        let appEnd = try XCTUnwrap(package.range(of: "]),", range: app.upperBound..<package.endIndex))
        let appDependencies = String(package[app.upperBound..<appEnd.lowerBound])
        for mlx in ["MLX", "LodestarMLX", "Tokenizers", "HuggingFace"] {
            XCTAssertFalse(appDependencies.contains("\"\(mlx)"), "the app links no \(mlx)")
        }
        let ears = try XCTUnwrap(package.range(of: ".target(name: \"LodestarEars\""))
        let earsLine = package[ears.lowerBound...].prefix { $0 != "\n" }
        XCTAssertFalse(earsLine.contains("MLX"), "the ears the app links carry no MLX")
        for directory in ["lodestar", "LodestarEars"] {
            let files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("Sources/\(directory)"), includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let code = try String(contentsOf: file, encoding: .utf8)
                XCTAssertNil(code.range(of: #"(?m)^import (MLX|Tokenizers|Hub|LodestarMLX)"#, options: .regularExpression),
                             "\(directory)/\(file.lastPathComponent) imports MLX")
            }
        }
    }
}
