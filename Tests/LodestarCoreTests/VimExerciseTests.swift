import XCTest
@testable import LodestarCore

/// Every key the editor can hear, thrown at it in bulk. These assert
/// almost nothing about meaning — the behavioral tests do that — and
/// everything about survival: no key, operator, target, text object,
/// or storm of them may crash the machine or leave the cursor outside
/// the buffer. A draft is a surface the hands trust with anything.
final class VimExerciseTests: XCTestCase {
    private static let corpus = [
        "",
        "a",
        "\n",
        "\n\n\n",
        "hello world",
        "one two three\nfour five\nsix",
        "  indented\n\ttabbed\nx",
        "line ends here\n",
        "emoji 🎉 café naïve 日本語 text",
        "(pairs [of] {every} <kind> \"and\" 'quotes')",
        String(repeating: "wrap ", count: 60),
    ]

    private static let printables: [Character] =
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        + Array("$^;,~%.!@#&*()[]{}<>/?'\"-_=+|\\` ")

    private static let singles: [Vim.Key] =
        printables.map { .char($0) } + [.escape, .delete, .left, .right, .up, .down,
                                        .control("r"), .control("d"), .control("u"), .control("o")]

    private func check(_ buffer: Draft.Buffer, _ context: String) {
        XCTAssertTrue((0...buffer.count).contains(buffer.cursor),
                      "cursor \(buffer.cursor) outside 0...\(buffer.count) after \(context)")
    }

    private func fresh(_ text: String, cursor: Int) -> (Vim, Draft.Buffer) {
        var buffer = Draft.Buffer(text: text)
        buffer.setCursor(min(cursor, buffer.count))
        var vim = Vim()
        vim.enterNormal(&buffer)
        return (vim, buffer)
    }

    func testEverySingleKeyOnEveryState() {
        for text in Self.corpus {
            for cursor in Set([0, text.count / 2, max(0, text.count - 1), text.count]) {
                for key in Self.singles {
                    var (vim, buffer) = fresh(text, cursor: cursor)
                    _ = vim.key(key, buffer: &buffer, pasteboard: { "clip" })
                    check(buffer, "\(key) on \(text.prefix(12))… at \(cursor)")
                }
            }
        }
    }

    func testEveryOperatorWithEveryFollowingKey() {
        for text in ["one two three\nfour five\nsix", "a", "", "(pairs [of] {every} <kind> \"and\" 'quotes')"] {
            for op: Character in ["d", "c", "y"] {
                for key in Self.singles {
                    var (vim, buffer) = fresh(text, cursor: text.isEmpty ? 0 : 2)
                    _ = vim.key(.char(op), buffer: &buffer, pasteboard: { "clip" })
                    _ = vim.key(key, buffer: &buffer, pasteboard: { "clip" })
                    // An awaited find or replace still wants its target.
                    _ = vim.key(.char("x"), buffer: &buffer, pasteboard: { "clip" })
                    check(buffer, "\(op) then \(key) on \(text.prefix(12))…")
                }
            }
        }
    }

    func testEveryAwaitedTargetForFindsAndReplace() {
        for text in ["one two three\nfour five\nsix", "🎉 café\nnaïve"] {
            for kind: Character in ["f", "t", "F", "T", "r"] {
                for target in Self.printables {
                    var (vim, buffer) = fresh(text, cursor: 4)
                    _ = vim.key(.char(kind), buffer: &buffer, pasteboard: { nil })
                    _ = vim.key(.char(target), buffer: &buffer, pasteboard: { nil })
                    check(buffer, "\(kind)\(target) on \(text.prefix(8))…")
                }
            }
        }
    }

    func testEveryTextObjectThroughEveryOperator() {
        let text = "words (in) [all] {the} <kinds> \"of\" 'pairs' here\nsecond paragraph"
        for op: Character in ["d", "c", "y", "v"] {
            for around: Character in ["i", "a"] {
                for object: Character in Array("wWsp\"'()[]{}<>bBt") {
                    var (vim, buffer) = fresh(text, cursor: 8)
                    _ = vim.key(.char(op), buffer: &buffer, pasteboard: { nil })
                    _ = vim.key(.char(around), buffer: &buffer, pasteboard: { nil })
                    _ = vim.key(.char(object), buffer: &buffer, pasteboard: { nil })
                    check(buffer, "\(op)\(around)\(object)")
                }
            }
        }
    }

    /// Deterministic storms: thousands of keys in a row, with the visual
    /// seam attached the way the app attaches it, on every corpus text.
    /// Any abort here is the crash the app would have shipped.
    func testSeededKeyStorms() {
        var state: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }
        for text in Self.corpus {
            var (vim, buffer) = fresh(text, cursor: 0)
            vim.visualLine = { buffer, index, down in
                let landed = down ? index + 8 : index - 8
                return (0...buffer.count).contains(landed) ? landed : nil
            }
            for turn in 0..<2000 {
                let key = Self.singles[next(Self.singles.count)]
                _ = vim.key(key, buffer: &buffer, pasteboard: { turn % 3 == 0 ? "clip" : nil })
                if case .insert = vim.mode {
                    // The shell types through its own path in insert mode;
                    // here a short burst stands in for it, then esc.
                    vim.typed("ab c")
                    buffer.type("ab c")
                    _ = vim.key(.escape, buffer: &buffer, pasteboard: { nil })
                    vim.leaveInsert(&buffer)
                }
                check(buffer, "storm turn \(turn) on \(text.prefix(8))…")
            }
        }
    }
}
