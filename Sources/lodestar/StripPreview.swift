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
                  app bundle: String? = nil, minutes: Double = 3,
                  kind: Clipboard.Kind = .text) -> Clipboard.Clip {
            Clipboard.Clip(id: id, kind: kind,
                           created: Date().addingTimeInterval(-60 * minutes),
                           sourceBundleID: bundle,
                           sourceAppName: bundle == nil ? nil : "Ghostty",
                           preview: text, bytes: text.utf8.count,
                           nativeTypes: [], pinnedSlot: slot)
        }

        let pins = [
            clip("p1", "https://lodestar.vaccone.software", slot: 1, app: "com.mitchellh.ghostty"),
            clip("p2", "rvaccone@example.com", slot: 2),
            clip("p4", "image 1200×800", slot: 4, kind: .image),
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
        // The real menu, not a copy of it — the harness must not drift.
        let actions = HotkeyEngine.panelActions(for: target)

        // 5 and 6 are the other two surfaces that draw key-and-label rows,
        // shown so the three can be compared against each other.
        if variant == 5 {
            let sheet = CheatSheet()
            sheet.toggle(sections: {
                [CheatSheet.Section(header: "verbs", rows: [
                    GuideRow(key: "␣", label: "searcher"),
                    GuideRow(key: "⏎", label: "web bar — links · domains · search"),
                    GuideRow(key: "1…9", label: "jump to window by position"),
                    GuideRow(key: "⇧⌘V", label: "clipboard — label pastes · ⌘ actions"),
                ]),
                 CheatSheet.Section(header: "motion", rows: [
                    GuideRow(key: "J K", label: "down · up"),
                    GuideRow(key: "⇥", label: "next pane"),
                    GuideRow(key: "esc", label: "clear a chain"),
                 ])]
            })
            app.run()
        }
        if variant == 6 {
            let hud = HUD()
            func appIcon(_ path: String) -> NSImage? {
                FileManager.default.fileExists(atPath: path)
                    ? NSWorkspace.shared.icon(forFile: path) : nil
            }
            hud.showGuide(title: "lode", rows: [
                GuideRow(key: "W", label: "Safari",
                         icon: appIcon("/Applications/Safari.app")),
                GuideRow(key: "E", label: "Mail",
                         icon: appIcon("/System/Applications/Mail.app")),
                GuideRow(key: "N", label: "Notes",
                         icon: appIcon("/System/Applications/Notes.app")),
                GuideRow(key: "→ D", label: "development"),
            ], footer: "esc clears")
            app.run()
        }

        if variant == 7 {
            // A guide with no icons at all, as the scroll guide is.
            let hud = HUD()
            hud.showGuide(title: "scroll", rows: [
                GuideRow(key: "J K", label: "down · up"),
                GuideRow(key: "D U", label: "half-page down · up"),
                GuideRow(key: "⇥", label: "next pane"),
            ], footer: "esc leaves")
            app.run()
        }

        if variant == 8 {
            let held = SearcherRowPreview.show()
            _ = held
            app.run()
        }

        if (9...14).contains(variant) {
            let held = OptionsCard.preview(variant - 8)
            _ = held
            app.run()
        }

        // 15 puts both menus on screen at once, over identical background,
        // which is the only honest way to compare their materials.
        var companion: [OptionsCard]?
        if variant == 15 { companion = OptionsCard.preview(1) }
        _ = companion

        let strip = ClipboardStrip()
        strip.show(recents: recents, pins: pins, thumbnail: { _ in nil },
                   band: .actions(actions), selection: 0, actingOn: target.id)
        app.run()
    }
}
#endif
