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
    private static var heldImageDoor: ImageDoor?

    /// A screenshot that never happened: a window's worth of dark glass
    /// with a few lines on it, so the door is photographed with pixels
    /// that are nobody's.
    static func sampleImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(srgbRed: 0.17, green: 0.17, blue: 0.2, alpha: 1).setFill()
        NSRect(x: 0, y: height - 44, width: width, height: 44).fill()
        for row in 0..<12 {
            let y = height - 100 - row * 56
            let w = [520, 760, 640, 900, 410, 700][row % 6]
            NSColor(srgbRed: 0.3, green: 0.3, blue: 0.34, alpha: 1).setFill()
            NSRect(x: 60, y: y, width: w, height: 14).fill()
        }
        NSColor(srgbRed: 1, green: 0.31, blue: 0, alpha: 1).setFill()
        NSRect(x: 60, y: height - 100 - 3 * 56, width: 640, height: 14).fill()
        image.unlockFocus()
        return image
    }
    private static var heldLink: LinkChip?
    private static var heldStrip: ClipboardStrip?
    private static var heldHover: EditorHover?
    private static var heldCoachHUD: HUD?
    private static var heldPreviewWindow: NSWindow?
    private static var heldBadges: IndexBadges?
    private static var heldMarks: EditorMarks?
    private static var heldOverlay: SelectOverlay?

    /// The flat ground alone, for a harness that stages its own panels.
    static func stageOnly() { stage() }

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
            app.appearance = NSAppearance(named: StageView.light ? .aqua : .darkAqua)
            // `LODESTAR_FLIP=1`: start in this look and turn to the other
            // three seconds in, the way the Mac turns at sunrise, to see
            // what a standing surface does when the look changes under it.
            if ProcessInfo.processInfo.environment["LODESTAR_FLIP"] != nil {
                let to: NSAppearance.Name = StageView.light ? .darkAqua : .aqua
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    app.appearance = NSAppearance(named: to)
                    StageView.light = to == .aqua
                    Glass.followSystemAppearance()
                    for window in app.windows { window.contentView?.needsDisplay = true }
                    if ProcessInfo.processInfo.environment["LODESTAR_FLIP"] == "trace" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            func walk(_ view: NSView, _ depth: Int) {
                                if view is ToneView {
                                    let c = view.layer?.backgroundColor?.components ?? []
                                    FileHandle.standardError.write("tone \(view.effectiveAppearance.name.rawValue) \(c)\n".data(using: .utf8)!)
                                }
                                for sub in view.subviews { walk(sub, depth + 1) }
                            }
                            for window in app.windows {
                                FileHandle.standardError.write("window \(type(of: window)) \(window.effectiveAppearance.name.rawValue)\n".data(using: .utf8)!)
                                if let content = window.contentView { walk(content, 0) }
                            }
                        }
                    }
                }
            }
            // `LODESTAR_GROUND=light|dark` stages the other ground under
            // this appearance. Glass composites what is behind it, so a
            // veil's weight only shows over a ground that disagrees with it.
            if let other = ProcessInfo.processInfo.environment["LODESTAR_GROUND"] {
                StageView.light = other == "light"
            }
            // `LODESTAR_ACCENT=orange` stages Lodestar's own accent.
            if ProcessInfo.processInfo.environment["LODESTAR_ACCENT"] == "orange" {
                BarTheme.accentColor = { BarTheme.accent(for: .orange) }
            }
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
                [CheatSheet.Section(header: "Verbs", rows: [
                    GuideRow(key: "␣", label: "Launcher"),
                    GuideRow(key: "⏎", label: "Ask: links · domains · search"),
                    GuideRow(key: "1…9", label: "Jump to window by position"),
                    GuideRow(key: "⇧⌘V", label: "Clipboard: label pastes · ⌘ actions"),
                ]),
                 CheatSheet.Section(header: "Motion", rows: [
                    GuideRow(key: "J K", label: "Down · up"),
                    GuideRow(key: "/", label: "Aim at a word"),
                    GuideRow(key: "esc", label: "Clear a chain"),
                 ])]
            })
            app.run()
        }
        // 19: the pill in its three states — PILL=standing|listening|typing.
        if variant == 19 {
            let pill = ModePill()
            let which = ProcessInfo.processInfo.environment["PILL"] ?? "standing"
            let icon = NSWorkspace.shared.icon(forFile: "/Applications/Slack.app")
            switch which {
            case "listening":
                pill.show(.init(mode: .click, app: "Brave", icon: NSWorkspace.shared.icon(forFile: "/Applications/Brave Browser.app"),
                                listening: true, text: nil))
            case "typing":
                pill.show(.init(mode: .select, app: "Ghostty", icon: NSWorkspace.shared.icon(forFile: "/Applications/Ghostty.app"),
                                listening: true, text: "thr"))
            default:
                pill.show(.init(mode: .scroll, app: "Slack", icon: icon, listening: false, text: nil))
            }
            app.run()
        }
        if variant == 6 {
            let hud = HUD()
            func appIcon(_ path: String) -> NSImage? {
                FileManager.default.fileExists(atPath: path)
                    ? NSWorkspace.shared.icon(forFile: path) : nil
            }
            hud.showGuide(keys: ["lode"], rows: [
                GuideRow(key: "W", label: "Safari",
                         icon: appIcon("/Applications/Safari.app")),
                GuideRow(key: "E", label: "Mail",
                         icon: appIcon("/System/Applications/Mail.app")),
                GuideRow(key: "N", label: "Notes",
                         icon: appIcon("/System/Applications/Notes.app")),
                GuideRow(key: "→ D", label: "Development"),
            ])
            app.run()
        }

        if variant == 7 {
            // A guide with no icons at all, as the scroll guide is.
            let hud = HUD()
            hud.showGuide(mark: "arrow.up.and.down", keys: ["lode", "`"], rows: [
                GuideRow(key: "J K", label: "Down · up"),
                GuideRow(key: "D U", label: "Half-page down · up"),
                GuideRow(key: "/", label: "Aim at a word"),
            ])
            app.run()
        }

        // 18: the Ask bar, over a synthetic config. Synthetic on purpose — the
        // real one would put the user's own profile names on a public page.
        if variant == 18 {
            let json = """
            {
              "web": {
                "links": {
                  "docs": { "url": "developer.apple.com/documentation", "profile": "brave:Work" },
                  "hn": { "url": "news.ycombinator.com" }
                },
                "routes": { "github.com": "brave:Work" },
                "fallback": "brave:Personal"
              }
            }
            """
            var problems: [String] = []
            let tree = (try? Json.parse(json)) ?? [:]
            let config = Config.build(from: tree, problems: &problems)
            let held = WebBarController.preview(query: ProcessInfo.processInfo.environment["ASK"] ?? "github.com/vaccone-software", config: config)
            _ = held
            app.run()
        }

        if variant == 8 {
            let held = SearcherRowPreview.show()
            _ = held
            app.run()
        }

        // 20…40 stage the first launch (see `WalkController.preview`): the
        // welcome, the permission and the wait, a door's walk
        // (LODESTAR_WALK_DOOR), then the curriculum's lessons and a proven
        // one. LODESTAR_EMPTY_GRAPH stages them with no graph.
        if (20...40).contains(variant) {
            let held = WalkController.preview(variant - 20,
                                              empty: ProcessInfo.processInfo.environment["LODESTAR_EMPTY_GRAPH"] != nil)
            _ = held
            app.run()
        }

        // 45…47 Send Feedback: the note being written, one that could not
        // be sent, and the thanks (see `FeedbackController.preview`).
        if (45...47).contains(variant) {
            let held = FeedbackController.preview(variant)
            _ = held
            app.run()
        }

        // 89 the settings overview, 90…99 each place by its digit.
        if (89...99).contains(variant) {
            let held = SettingsController.preview(variant - 90)
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

        // 73: the speak door holding its keys — the end state of lode ?,
        // photographed so the motion can be designed against the real
        // thing rather than against a drawing of it.
        if variant == 73 {
            DispatchQueue.main.async {
                let panel = DraftPanel.preview(0)
                heldDraft = panel
                panel.showKeys(HotkeyEngine.draftSections(editor: .insert, card: false))
            }
            app.run()
        }

        // 16: the commands bar, mid-search over synthetic menus.
        if variant == 16 {
            let held = CommandsBarController.preview(query: "pa")
            _ = held
            app.run()
        }

        // 60 the meeting chip three minutes out, 61 the calendar prime
        // card, 130 the chip at the door. Constructed on the run loop: a
        // panel born before the app finishes launching never reaches the
        // window server, and the chip is never key, so nothing later would
        // rescue it.
        if variant == 60 || variant == 61 || variant == 130 {
            DispatchQueue.main.async {
                heldMeeting = variant == 130
                    ? MeetingController.preview(0, startingIn: 42)
                    : MeetingController.preview(variant - 60, startingIn: 3 * 60 + 30)
            }
            app.run()
        }

        // 62: the coach chip, worded exactly as Coach.chip words a bind
        // offer — the copy here quotes the real templates, not a mock.
        if variant == 62 || variant == 131 {
            let hud = HUD()
            func icon(_ bundle: String) -> NSImage? {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
            let offer = variant == 62
                ? CoachCard.Offer(sentence: "Notes could be one key away", icons: [icon("com.apple.Notes")].compactMap { $0 },
                                  name: "Notes", address: ["lode", "N"], record: "Searched 31 times across 6 weeks",
                                  accept: {}, decline: {})
                : CoachCard.Offer(sentence: "Slack and Zoom could stand side by side with one key",
                                  icons: [icon("com.tinyspeck.slackmacgap"), icon("us.zoom.xos")].compactMap { $0 },
                                  name: "Slack and Zoom", address: ["lode", "'", "W"],
                                  record: "You arrange them side by side about four times a week",
                                  accept: {}, decline: {})
            hud.showCoach(offer)
            heldCoachHUD = hud
            app.run()
        }

        // 64: the coach's decline note, the voice for as long as a note
        // stands (held open here so it can be photographed).
        if variant == 64 {
            let hud = HUD()
            hud.showVoice(sentence: Coach.declinedNote, detail: nil, rows: [], owner: .flash)
            app.run()
        }

        // 134: Lodestar speaking about itself at launch and while it updates,
        // VOICE=ready|found|taking|updated; LIT= the share of the mark lit
        // while found is downloading.
        if variant == 134 {
            let hud = HUD()
            let env = ProcessInfo.processInfo.environment
            switch env["VOICE"] ?? "found" {
            case "ready":
                hud.showVoice(sentence: AppDelegate.readyNote, keymap: AppDelegate.readyKeymap, detail: nil, rows: [],
                              owner: .flash, mark: 1)
            case "taking":
                let words = UpdateController.Voice.takingOver("0.45.5")
                hud.showVoice(sentence: words.0, detail: words.1, rows: [], owner: .flash, mark: 1)
            case "updated":
                let words = UpdateController.Voice.updated("0.45.5")
                hud.showVoice(sentence: words.0, detail: words.1, rows: [], owner: .flash, mark: 1)
            default:
                let words = UpdateController.Voice.found("v0.45.5")
                hud.showVoice(sentence: words.0, detail: words.1, rows: [], owner: .flash,
                              mark: Double(env["LIT"] ?? "") ?? 0.6)
            }
            app.run()
        }

        // 135: the walk's cue, STAND=30|60: the mark lit as far into the
        // hour as the stretch has run.
        if variant == 135 {
            let hud = HUD()
            let minutes = ProcessInfo.processInfo.environment["STAND"] == "60" ? 60 : 30
            hud.showVoice(sentence: StandCue.sentence(minutes: minutes), detail: StandCue.instruction, rows: [],
                          owner: .flash, mark: minutes == 60 ? 1 : 0.5)
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

        // 80: an image card open in its door above the strip, the card lit
        // beneath; 81: the save band, offering a name and naming the folder.
        if variant == 80 || variant == 81 {
            let shot = clip("r5", "image 1600×1000\nswift build -c release",
                            app: "com.mitchellh.ghostty", minutes: 2, kind: .image)
            let image = sampleImage(width: 1600, height: 1000)
            let strip = ClipboardStrip()
            let thumbnail: (String) -> NSImage? = { $0 == "r5" ? image : nil }
            if variant == 80 {
                DispatchQueue.main.async {
                    heldImageDoor = ImageDoor()
                    heldImageDoor?.show(image: image, pixels: CGSize(width: 1600, height: 1000),
                                        caption: "1600×1000 · Ghostty · 2m ago")
                }
            } else {
                strip.show(recents: [shot] + recents, pins: pins, thumbnail: thumbnail,
                           band: .save(name: "Ghostty 2026-09-06 at 12.04.31.png",
                                       offered: "Ghostty 2026-09-06 at 12.04.31.png",
                                       folder: "~/Downloads"),
                           selection: 0, actingOn: shot.id)
            }
            app.run()
        }

        // 100…106: the next sheet, staged for approval before anything is
        // built. Real materials throughout: the pill, the voice surface,
        // the keycaps, the glass.
        if (100...107).contains(variant) {
            DispatchQueue.main.async { NextSheet.run(variant) }
            app.run()
        }

        // 128, 129: the editor's card over a word, a spelling mark (fix,
        // your word, Learn) and a grammar mark (fix, your words).
        // 132: the marks over another app's text: the editor's underline
        // and lens tags on two neighbouring words, select's underlined
        // matches with their keys and the anchor, click hint keys. 133:
        // the peek's numerals over three windows.
        if variant == 132 || variant == 133 {
            DispatchQueue.main.async {
                let dark = Tone.systemDark
                let frame = NSRect(x: 260, y: 260, width: 760, height: 300)
                let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.backgroundColor = dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1) : .white
                window.level = .floating
                let text = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
                text.drawsBackground = false
                text.textContainerInset = NSSize(width: 28, height: 56)
                text.font = BarTheme.titleFont
                text.textColor = dark ? NSColor(white: 0.84, alpha: 1) : NSColor(white: 0.11, alpha: 1)
                let body = "I think teh recieve date moved again.\n\n\nThe review moved to Thursday after the standup.\nBring the Thursday notes.\n\nReply    Forward    Archive"
                text.string = body
                window.contentView = text
                window.orderFrontRegardless()
                heldPreviewWindow = window
                guard let primary = NSScreen.screens.first else { return }
                func quartz(_ word: String, _ nth: Int = 0) -> CGRect {
                    var range = NSRange(location: 0, length: 0)
                    var from = 0
                    for _ in 0...nth {
                        range = (body as NSString).range(of: word, range: NSRange(location: from, length: (body as NSString).length - from))
                        from = range.location + range.length
                    }
                    var actual = NSRange()
                    let r = text.firstRect(forCharacterRange: range, actualRange: &actual)
                    return CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
                }
                let windowQuartz = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
                if variant == 133 {
                    let badges = IndexBadges()
                    badges.show([(1, CGRect(x: windowQuartz.minX, y: windowQuartz.minY, width: windowQuartz.width / 2, height: windowQuartz.height)),
                                 (2, CGRect(x: windowQuartz.midX, y: windowQuartz.minY, width: windowQuartz.width / 2, height: windowQuartz.height / 2)),
                                 (3, CGRect(x: windowQuartz.midX, y: windowQuartz.midY, width: windowQuartz.width / 2, height: windowQuartz.height / 2))])
                    heldBadges = badges
                    return
                }
                let marks = EditorMarks()
                marks.show([quartz("teh"), quartz("recieve")], over: windowQuartz)
                heldMarks = marks
                let overlay = SelectOverlay()
                overlay.show(chips: [
                    .init(label: "j", frames: [quartz("teh")], style: .tag("the")),
                    .init(label: "k", frames: [quartz("recieve")], style: .tag("receive")),
                    .init(label: "l", frames: [quartz("Thursday", 1)], style: .match),
                    .init(label: "f", frames: [quartz("Reply")], style: .target),
                    .init(label: "d", frames: [quartz("Forward")], style: .target),
                    .init(label: "s", frames: [quartz("Archive")], style: .target),
                ], anchor: [quartz("Thursday")], over: windowQuartz)
                heldOverlay = overlay
            }
            app.run()
        }

        if variant == 128 || variant == 129 {
            let hover = EditorHover()
            hover.learnable = { $0.issue.kind == .spelling }
            heldHover = hover
            let issue = variant == 128
                ? EditorIssue(range: NSRange(location: 0, length: 7), original: "recieve", replacement: "receive",
                              kind: .spelling)
                : EditorIssue(range: NSRange(location: 0, length: 4), original: "less", replacement: "fewer",
                              kind: .grammar)
            DispatchQueue.main.async {
                hover.show(EditorController.Mark(issue: issue, rect: CGRect(x: 700, y: 420, width: 90, height: 22)))
            }
            app.run()
        }

        // 120…126: Keep, level. At rest; typing a search; ⌥ held while
        // searching; ⌃ held showing readings; the source list; a keepsake
        // being named; the actions on J. Sample clips only.
        if (120...126).contains(variant) {
            func made(_ id: String, _ text: String, _ app: String, _ minutes: Double,
                      slot: Int? = nil, name: String? = nil, kind: Clipboard.Kind = .text) -> Clipboard.Clip {
                Clipboard.Clip(id: id, kind: kind, created: Date().addingTimeInterval(-60 * minutes),
                               sourceBundleID: "sample.\(app)", sourceAppName: app,
                               preview: text, bytes: text.utf8.count, pinnedSlot: slot, keptName: name)
            }
            let kept = [
                made("k4", "Prepare a change request for the change below. Fill in the risk, the rollback and the test plan.",
                     "Notes", 9000, slot: 4, name: "Change request"),
                made("k3", "Review this diff for correctness first, then simplicity, then naming.",
                     "Notes", 8000, slot: 3, name: "Review prompt"),
                made("k2", "image 1200×800", "Preview", 7000, slot: 2, name: "The image", kind: .image),
            ]
            let rest = [
                made("j", "git push origin local/keep && gh pr view --web", "Ghostty", 0.2),
                made("k", "https://developer.apple.com/documentation/appkit/nspasteboard", "Brave", 2),
                made("l", "Can you send the build number from this morning?", "Slack", 6),
                made("s1", "#FF4F00", "Brave", 9),
                made("f", "sk_live_51HgL0K2eZvKYlo2C3f9a", "Ghostty", 31),
                made("d", "1200 + 40", "Notes", 52),
                made("s", "npm run build", "Ghostty", 70),
                made("a", "Q3 roadmap review moved to Thursday", "Mail", 120),
            ]
            let found = [rest[6], rest[0], rest[2]]
            let image = sampleImage(width: 1200, height: 800)
            let thumbnail: (String) -> NSImage? = { $0 == "k2" ? image : nil }
            let strip = ClipboardStrip()
            heldStrip = strip
            DispatchQueue.main.async {
                switch variant {
                case 121:
                    strip.show(recents: found, pins: kept, thumbnail: thumbnail, band: .search("build"),
                               selection: 0, matches: 3)
                case 122:
                    strip.show(recents: found, pins: kept, thumbnail: thumbnail, band: .search("build"),
                               selection: 0, held: .option, matches: 3)
                case 123:
                    strip.show(recents: rest, pins: kept, thumbnail: thumbnail, band: .none,
                               selection: 0, held: .control)
                case 124:
                    strip.show(recents: found, pins: kept, thumbnail: thumbnail, band: .search("build"),
                               selection: 0, matches: 3,
                               sourceMenu: .init(typed: "", rows: [.init(name: "All apps", count: 214),
                                                                    .init(name: "Brave", count: 38),
                                                                    .init(name: "Ghostty", count: 71),
                                                                    .init(name: "Mail", count: 6),
                                                                    .init(name: "Notes", count: 12),
                                                                    .init(name: "Slack", count: 29)],
                                                 selection: 0))
                case 125:
                    var keptNow = kept
                    var fresh = rest[0]
                    fresh.pinnedSlot = 1
                    keptNow.append(fresh)
                    strip.show(recents: Array(rest.dropFirst()), pins: keptNow, thumbnail: thumbnail,
                               band: .none, selection: 0,
                               naming: .init(id: "j", text: "git push origin", selected: true))
                case 126:
                    strip.show(recents: rest, pins: kept, thumbnail: thumbnail,
                               band: .actions(HotkeyEngine.panelActions(for: rest[0])),
                               selection: 0, actingOn: "j")
                default:
                    strip.show(recents: rest, pins: kept, thumbnail: thumbnail, band: .none, selection: 0)
                }
            }
            app.run()
        }

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
        } else if variant == 82 {
            // 82: the cards read as a moment, with Tokyo kept: Unix seconds
            // and milliseconds, an ISO date, the mail format, a day, and a
            // time from last week.
            strip.timeZones = [TimeZone(identifier: "Asia/Tokyo")!]
            let hour = 3600.0
            let unix = { (seconds: Double) in String(Int(Date().timeIntervalSince1970 - seconds)) }
            strip.show(recents: [clip("t0", unix(6 * hour), app: "com.mitchellh.ghostty", minutes: 1),
                                 clip("t1", unix(30 * hour) + "000", minutes: 4),
                                 clip("t2", "2026-09-25T13:14:17.123+09:00", minutes: 6),
                                 clip("t3", "Fri, 25 Sep 2026 13:14:17 +0000", minutes: 30),
                                 clip("t4", "2026-10-02", minutes: 50),
                                 clip("t5", unix(9 * 24 * hour), minutes: 70)],
                       pins: pins, thumbnail: { _ in nil }, band: .none, selection: 0)
        } else if variant == 84 {
            // 84: measurements read into imperial, one already imperial
            // left plain, and arithmetic read as its answer.
            strip.units = .imperial
            strip.show(recents: [clip("m0", "5 km", minutes: 1),
                                 clip("m1", "180 cm", minutes: 3),
                                 clip("m2", "500 mL", minutes: 8),
                                 clip("m3", "22 °C", minutes: 12),
                                 clip("m4", "3 mi", minutes: 20),
                                 clip("m5", "1234 * 1.08", minutes: 30),
                                 clip("m6", "(12 + 7) / 3", minutes: 45)],
                       pins: pins, thumbnail: { _ in nil }, band: .none, selection: 0)
        } else if variant == 83 {
            // 83: the cards drawn as a color, named, in each notation,
            // white and near black for the edge, a translucent one, and an
            // issue number that stays text.
            strip.show(recents: [clip("c0", "#FF4F00", minutes: 1),
                                 clip("c1", "3478F6", minutes: 3),
                                 clip("c2", "rgb(52 199 89 / 50%)", minutes: 8),
                                 clip("c3", "hsl(280deg 60% 55%)", minutes: 20),
                                 clip("c4", "#FFFFFF", minutes: 40),
                                 clip("c5", "#1E1E1E", minutes: 45),
                                 clip("c6", "#123", minutes: 55)],
                       pins: pins, thumbnail: { _ in nil }, band: .none, selection: 0)
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
