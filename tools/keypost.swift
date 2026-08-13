// E2E key driver for lodestar. Posts synthetic keystrokes.
// Tokens: "s" = lode+s · "+s" = lode+shift+s · ".s" = plain s (no lode)
// Example: keypost w x        -> lode+W, lode+X (chain)
//          keypost space .m .u .s .return   -> searcher, type "mus", enter
import CoreGraphics
import Foundation

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
    "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
    "k": 40, "n": 45, "m": 46,
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
]

let rightCmdBit: UInt64 = 0x0010
var delayMs: UInt32 = 260

for token in CommandLine.arguments.dropFirst() {
    if token.hasPrefix("delay=") {
        delayMs = UInt32(token.dropFirst(6)) ?? delayMs
        continue
    }
    var name = token
    var shift = false
    var plain = false
    while name.hasPrefix("+") || name.hasPrefix(".") {
        if name.hasPrefix("+") { shift = true }
        if name.hasPrefix(".") { plain = true }
        name.removeFirst()
    }
    guard let code = codes[name] else {
        FileHandle.standardError.write(Data("unknown key '\(name)'\n".utf8))
        exit(2)
    }
    var flags = CGEventFlags()
    if !plain {
        flags.insert(.maskCommand)
        flags = CGEventFlags(rawValue: flags.rawValue | rightCmdBit)
    }
    if shift { flags.insert(.maskShift) }

    let source = CGEventSource(stateID: .hidSystemState)
    // Beside-detection reads the *physical* shift key state, so a shifted
    // token presses a real (synthetic) shift key around the main key.
    if shift, let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) {
        shiftDown.flags = [.maskShift]
        shiftDown.post(tap: .cgSessionEventTap)
        usleep(50_000)
    }
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { exit(3) }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cgSessionEventTap)
    usleep(40_000)
    up.post(tap: .cgSessionEventTap)
    if shift, let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) {
        usleep(50_000)
        shiftUp.flags = []
        shiftUp.post(tap: .cgSessionEventTap)
    }
    usleep(delayMs * 1000)
}
