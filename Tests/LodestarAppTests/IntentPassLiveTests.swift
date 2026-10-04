import XCTest
@testable import lodestar
@testable import LodestarCore

/// The intent pass on the real model, over the probe's hand-written text
/// set (in the checker's fixture): edits it should make, ordinary prompts
/// and traps it must leave alone. Off by default — it loads gigabytes of
/// weights — and on by environment:
///
///     LODESTAR_INTENT_LIVE=standard swift test --filter IntentPassLiveTests
final class IntentPassLiveTests: XCTestCase {
    private struct Fixture: Decodable {
        let textset: [Item]
        struct Item: Decodable { let id, kind, input, expected: String; let alt: [String] }
    }

    /// Loose, as the probe compared: words and their case, line breaks, not
    /// the closing mark.
    private func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.split(whereSeparator: { $0 == " " }).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".?! \n"))
        }
        return norm(a) == norm(b)
    }

    @MainActor
    func testTheModelAgainstTheTextSet() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["LODESTAR_INTENT_LIVE"], let engine = EditorEngine(rawValue: name) else {
            throw XCTSkip("set LODESTAR_INTENT_LIVE to standard or full to run the real model")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../LodestarCoreTests/Fixtures/intent-checker.json").standardized
        let items = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).textset
        let model = EditorModel(engine: engine)
        let prompt = IntentPass.prompt(names: [
            "Lodestar", "Ghostty", "Claude Code", "Supabase", "Xonar", "Kindora", "Convex", "Expo", "Telegram",
            "MongoDB Compass", "Raycast", "Asana", "Brex", "Kagi", "Kinesis", "ZMK", "AeroSpace", "SwiftUI", "MLX",
            "UAT", "Proton Pass", "Vaccone",
        ])
        // The pass never loads the weights itself: the editor has.
        await model.prepare()
        let cold = await EditorModel(engine: engine).rewrite("Um, hi.", prompt: prompt)
        XCTAssertNil(cold, "not loaded, not asked")
        _ = await model.rewrite("Warm up.", prompt: prompt)
        var exact = 0, edits = 0, falseEdits = 0, gated = 0
        var times: [Double] = []
        for item in items {
            let started = Date()
            let answer = await model.rewrite(item.input, prompt: prompt)
            times.append(Date().timeIntervalSince(started))
            let (checked, verdict) = IntentPass.judge(said: item.input, answer: answer ?? "")
            let landed = checked ?? item.input
            if IntentPass.wants(item.input) { gated += 1 }
            if item.kind == "edit" {
                edits += 1
                if ([item.expected] + item.alt).contains(where: { same($0, landed) }) { exact += 1 }
            } else if !same(landed, item.input), !same(landed, item.expected) {
                // A trap's answer may be a conversion ("like slash compact"
                // is "/compact"); a miss is not damage, anything else is.
                falseEdits += 1
            }
            if env["SHOW_INTENT"] != nil {
                print("\(item.id) \(item.kind)\n  said   \(item.input)\n  model  \(answer ?? "—")\n"
                      + "  landed \(landed)\(verdict.map { $0.ok ? "" : "  (\($0.reason))" } ?? "")")
            }
        }
        await model.release(reason: "test done")
        times.sort()
        print(String(format: "intent · %@ · exact %d/%d · false edits %d/%d · gated %d/%d · p50 %.2fs p90 %.2fs",
                     engine.rawValue, exact, edits, falseEdits, items.count - edits, gated, items.count,
                     times[times.count / 2], times[times.count * 9 / 10]))
        // The probe, checked: Standard 26/28 and Full 26/28 exact, no false
        // edit on the 19 plain and trap items. A little room for MLX in
        // Swift against MLX in Python.
        XCTAssertGreaterThanOrEqual(exact, 23)
        XCTAssertEqual(falseEdits, 0)
    }
}
