#if DEBUG
import AppKit
import LodestarCore

/// A visual harness for the clipboard strip: renders one menu placement
/// against fixed sample clips so the layout can be looked at, not just
/// reasoned about. Debug-only — `swift build -c release` drops it.
enum StripPreview {
    static func run(_ variant: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        func clip(_ id: String, _ text: String, slot: Int? = nil,
                  app bundle: String? = nil, minutes: Double = 3) -> Clipboard.Clip {
            Clipboard.Clip(id: id, kind: .text,
                           created: Date().addingTimeInterval(-60 * minutes),
                           sourceBundleID: bundle,
                           sourceAppName: bundle == nil ? nil : "Ghostty",
                           preview: text, bytes: text.utf8.count,
                           nativeTypes: [], pinnedSlot: slot)
        }

        let pins = [
            clip("p1", "https://lodestar.vaccone.software", slot: 1, app: "com.mitchellh.ghostty"),
            clip("p2", "rvaccone@example.com", slot: 2),
            clip("p4", "SELECT * FROM windows WHERE space = 3;", slot: 4),
        ]
        let recents = [
            clip("r0", "swift build -c release --arch arm64", app: "com.mitchellh.ghostty", minutes: 0.2),
            clip("r1", "The quick brown fox jumps over the lazy dog and keeps going well past the edge of the card.", minutes: 8),
            clip("r2", "git commit -m \"Actions open where the card is\"", app: "com.mitchellh.ghostty", minutes: 40),
            clip("r3", "2PZMN57974", minutes: 300),
            clip("r4", "func actionFrame(for id: String?) -> NSRect", minutes: 1500),
        ]

        // Which card the menu hangs off, per variant.
        let target: Clipboard.Clip
        switch variant {
        case 1: target = pins[0]      // pin one, the tightest case
        case 2: target = pins[2]      // pin four, high in the column
        case 3: target = recents[0]   // first recent — must dodge pin one
        default: target = recents[2]  // a recent carrying the long label
        }
        var actions = [(key: "P", label: target.isPinned ? "unpin" : "pin"),
                       (key: "D", label: "delete")]
        if target.sourceAppName != nil { actions.append((key: "X", label: "never save from this app")) }
        if variant == 2 { actions.append((key: "S", label: "save")) }

        let strip = ClipboardStrip()
        strip.show(recents: recents, pins: pins, thumbnail: { _ in nil },
                   band: .actions(actions), selection: 0, actingOn: target.id)
        app.run()
    }
}
#endif
