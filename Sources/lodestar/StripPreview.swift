#if DEBUG
import AppKit
import LodestarCore

/// A visual harness for the clipboard strip: renders one menu placement
/// against fixed sample clips so the layout can be looked at, not just
/// reasoned about. Debug-only — `swift build -c release` drops it.
enum StripPreview {
    /// A full screen ground to photograph the panels against. Glass composites
    /// whatever is behind it, so a capture taken over a terminal has that
    /// terminal's text inside the panel — and whatever else was on screen.
    /// This is the one background that is repeatable and cannot leak anything.
    /// Held, or ARC frees them the moment the loop ends and the ground never
    /// appears.
    private static var stageWindows: [NSWindow] = []
    private static var heldMeeting: MeetingController?
    private static var heldDraft: DraftPanel?
    private static var heldLink: LinkChip?

    private static func stage() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            // Above another app's windows, below every panel it is a ground
            // for: .normal sits inside our own inactive app's layer and never
            // covers the terminal it was launched from.
            window.level = .floating
            window.isOpaque = true
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.contentView = StageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            stageWindows.append(window)
        }
    }

    static func run(_ variant: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let ground = ProcessInfo.processInfo.environment["LODESTAR_STAGE"] {
            // `light` is the whole process in the light appearance: the
            // tone the surfaces read, the colours the labels resolve, and
            // a paper ground, so light mode can be measured without
            // flipping the machine.
            StageView.light = ground == "light"
            if StageView.light { app.appearance = NSAppearance(named: .aqua) }
            // After the run loop is up: windows made before the app finishes
            // launching never reach the window server, and take the panel with
            // them.
            DispatchQueue.main.async { stage() }
        }

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
            clip("p2", "hello@example.com", slot: 2),
            clip("p4", "image 1200×800", slot: 4, kind: .image),
        ]
        let recents = [
            clip("r0", "swift build -c release --arch arm64", app: "com.mitchellh.ghostty", minutes: 0.2),
            clip("r1", "The quick brown fox jumps over the lazy dog and keeps going well past the edge of the card.", minutes: 8),
            clip("r2", "git commit -m \"Actions open where the card is\"", app: "com.mitchellh.ghostty", minutes: 40),
            clip("r3", "AB12CD34EF", minutes: 300),
            clip("r4", "func actionFrame(for id: String?) -> NSRect", minutes: 1500),
        ]

        /// One copy that was several things: what Finder puts on the board
        /// when three files are selected, and what the card has to say
        /// about it.
        func files(_ id: String, _ paths: [String], minutes: Double = 3) -> Clipboard.Clip {
            Clipboard.Clip(id: id, kind: .text,
                           created: Date().addingTimeInterval(-60 * minutes),
                           sourceBundleID: "com.apple.finder", sourceAppName: "Finder",
                           preview: paths.joined(separator: "\n"),
                           bytes: 600,
                           nativeTypes: [Clipboard.fileURLType],
                           otherItemTypes: Array(repeating: [Clipboard.fileURLType],
                                                 count: max(0, paths.count - 1)))
        }

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
                    GuideRow(key: "␣", label: "launcher"),
                    GuideRow(key: "⏎", label: "ask: links · domains · search"),
                    GuideRow(key: "1…9", label: "jump to window by position"),
                    GuideRow(key: "⇧⌘V", label: "clipboard: label pastes · ⌘ actions"),
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

        // 18: the Ask bar, over a synthetic config. Synthetic on purpose — the
        // real one would put the user's own profile names on a public page.
        if variant == 18 {
            let json = """
            {
              "web": {
                "links": {
                  "docs": "developer.apple.com/documentation",
                  "hn": "news.ycombinator.com"
                },
                "routes": { "github.com": "default" },
                "fallback": "default"
              }
            }
            """
            var problems: [String] = []
            let tree = (try? Json.parse(json)) ?? [:]
            let config = Config.build(from: tree, problems: &problems)
            let held = WebBarController.preview(query: "github.com/vaccone-software", config: config)
            _ = held
            app.run()
        }

        if variant == 8 {
            let held = SearcherRowPreview.show()
            _ = held
            app.run()
        }

        // 20…31 stage the walk: the door's three states, the companion's
        // eight steps, the closing card. 40…51 the same, with no graph.
        if (20...51).contains(variant) {
            let held = WalkController.preview(variant % 20, empty: variant >= 40)
            _ = held
            app.run()
        }

        // 70: the draft, speaking, with a ghost standing; 71 the edit door
        // in normal mode over a pulled field; 72 the website's photograph.
        // The panel is the real one.
        if variant == 70 || variant == 71 || variant == 72 {
            DispatchQueue.main.async {
                heldDraft = DraftPanel.preview(variant - 70)
            }
            app.run()
        }

        // 16: the commands bar, mid-search over synthetic menus.
        if variant == 16 {
            let held = CommandsBarController.preview(query: "pa")
            _ = held
            app.run()
        }

        // 60 the meeting chip, 61 the calendar prime card. Constructed on
        // the run loop: a panel born before the app finishes launching
        // never reaches the window server, and the chip is never key, so
        // nothing later would rescue it.
        if variant == 60 || variant == 61 {
            DispatchQueue.main.async {
                heldMeeting = MeetingController.preview(variant - 60)
            }
            app.run()
        }

        // 62: the coach chip, worded exactly as Coach.chip words a bind
        // offer — the copy here quotes the real templates, not a mock.
        if variant == 62 {
            let hud = HUD()
            hud.showGuide(title: "⌖ coach",
                          rows: [GuideRow(keys: ["lode", "lode"], label: "lode F → Figma",
                                          action: {}),
                                 GuideRow(keys: ["lode", "⌫"], label: "not this one",
                                          action: {})],
                          footer: "you searched for it 31 times across 6 weeks"
                              + " · about 40 seconds a week   ·   tap lode twice"
                              + " to bind it · lode ⌫ not this one · fades on its own")
            app.run()
        }

        // 63: the link chip — what a clicked link leaves behind when an
        // arrangement was standing and the screen deliberately did not move.
        if variant == 63 {
            DispatchQueue.main.async {
                heldLink = LinkChip()
                heldLink?.show(destination: "Brave (Xonar)",
                               icon: NSWorkspace.shared.icon(forFile: "/Applications/Safari.app"))
            }
            app.run()
        }

        // 70…78 the settings window, one pane per variant.
        if (70...78).contains(variant) {
            let held = SettingsController.preview(variant - 70)
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
        // 9 stages the search band instead of the menu: every chip wears ⌥,
        // because while the letters are the query that is what addresses a
        // card, and the first card is a copy that was three files.
        if variant == 9 {
            strip.show(recents: [files("f0", ["/Users/you/Reports/Q3 report.pdf",
                                              "/Users/you/Reports/Q3 notes.txt",
                                              "/Users/you/Reports/chart.png"], minutes: 1),
                                 recents[0], recents[2], recents[4]],
                       pins: pins, thumbnail: { _ in nil },
                       band: .search("report"), selection: 0)
        } else {
            strip.show(recents: recents, pins: pins, thumbnail: { _ in nil },
                       band: .actions(actions), selection: 0, actingOn: target.id)
        }
        app.run()
    }
}

/// The ground the panels are photographed against: the page's own near black,
/// with a trace of light so the glass has an edge to catch. Anything more
/// colourful competes with the one accent the page is allowed.
private final class StageView: NSView {
    static var light = false
    override func draw(_ dirtyRect: NSRect) {
        // srgbRed, not calibratedRed: Generic RGB converts lighter, and the
        // whole point is a ground the page cannot be told apart from.
        (Self.light ? NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 247 / 255, alpha: 1)
                    : NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1)).setFill()
        bounds.fill()
        // Flat, deliberately. Any light in the ground shows up as a visible
        // rectangle where the shot meets the page, and the panel carries its
        // own shadow and rim already.
    }
}

#endif
