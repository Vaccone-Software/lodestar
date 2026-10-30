import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The surfaces that stand over the work: the pill, the meeting's chip, the
/// draft, the coach, the notes and guides, Feedback and the walk.
enum GalleryChrome {
    private static func icon(_ path: String) -> NSImage? {
        FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    // MARK: - The pill

    static func pill(_ state: ModePill.State) throws -> (NSView, [AnyObject]) {
        var made: ModePill?
        return try withPresentationFrame(Stage.screen(1200, 800)) {
            try GalleryHost.surface(made: {
                made = ModePill()
                made?.show(state)
                return [made as Any as AnyObject]
            })
        }
    }

    // MARK: - The meeting's chip

    /// The chip as the meeting's own preview stages it, `offset` seconds
    /// before the meeting starts (negative once it has).
    static func meeting(startingIn offset: TimeInterval,
                        title: String = "Product sync") throws -> (NSView, [AnyObject]) {
        // On the stand-in display, as every stage's: off every real one, so
        // the chip stands where the harness put it and not where a smaller
        // display would have moved it.
        try withPresentationFrame(Stage.screen(1200, 800)) {
            try GalleryHost.surface(made: { [MeetingController.preview(0, startingIn: offset, title: title)] },
                                    where: { $0 is KeyablePanel })
        }
    }

    // MARK: - The draft

    static func draft(_ variant: Int) throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(Stage.screen(1600, 1000)) {
            try GalleryHost.surface(made: { [DraftPanel.preview(variant)] })
        }
    }

    /// The editor's lens: words marked in the accent, standing in normal mode.
    static func lens() throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(Stage.screen(1600, 1000)) {
            try GalleryHost.surface(made: {
                let panel = DraftPanel()
                let text = "The quick brown fox jumps over the lazy dog, definately twice."
                var buffer = Draft.Buffer(text: text, cursor: 10)
                buffer.setCursor(10)
                let marked = (text as NSString).range(of: "definately")
                var view = DraftView(buffer: buffer, mode: .normal, editor: .normal, speech: nil,
                                     inputs: [], systemInput: nil,
                                     destination: ("Messages", icon("/System/Applications/Messages.app")), replacing: true,
                                     style: .vim)
                view.editorMarks = [marked]
                panel.show(view)
                return [panel]
            })
        }
    }

    // MARK: - The coach, notes and guides

    private static func hud(_ show: @escaping (HUD) -> Void) throws -> (NSView, [AnyObject]) {
        var made: HUD?
        return try withPresentationFrame(Stage.screen(1400, 900)) {
            try GalleryHost.surface(made: {
                made = HUD()
                show(made!)
                return [made as Any as AnyObject]
            })
        }
    }

    static func coach(_ pair: Bool) throws -> (NSView, [AnyObject]) {
        try hud { hud in
            let notes = icon("/System/Applications/Notes.app").map { [$0] } ?? []
            let two = [icon("/System/Applications/Messages.app"), icon("/System/Applications/Mail.app")].compactMap { $0 }
            hud.showCoach(pair
                ? CoachCard.Offer(sentence: "Messages and Mail could stand side by side with one key", icons: two,
                                  name: "Messages and Mail", address: ["lode", "'", "W"],
                                  record: "You arrange them side by side about four times a week", accept: {}, decline: {})
                : CoachCard.Offer(sentence: "Notes could be one key away", icons: notes, name: "Notes",
                                  address: ["lode", "N"], record: "Searched 31 times across 6 weeks",
                                  accept: {}, decline: {}))
        }
    }

    /// A breath of two long names, its record whole with how far past chance they go, so it wraps
    /// beside `lode ⌫` and "Not now" on a card at its widest.
    static let wrappedRecord = CoachCard.record(from: "Activity Monitor and Brave Browser travel together 124×, 12 times more than chance")

    static func coachWrapped() throws -> (NSView, [AnyObject]) {
        try hud { hud in
            let two = [icon("/System/Applications/Utilities/Activity Monitor.app"),
                       icon("/Applications/Brave Browser.app") ?? icon("/Applications/Safari.app")
                           ?? icon("/System/Cryptexes/App/System/Applications/Safari.app")].compactMap { $0 }
            hud.showCoach(CoachCard.Offer(
                sentence: "Activity Monitor and Brave Browser could stand side by side with one key", icons: two,
                name: "Activity Monitor and Brave Browser", address: ["lode", "'", "W"],
                record: wrappedRecord, accept: {}, decline: {}))
        }
    }

    static func note(_ text: String, icon named: String? = nil) throws -> (NSView, [AnyObject]) {
        try hud { $0.flash(text, icon: named.flatMap(icon)) }
    }

    static func voice(_ sentence: String, detail: String?, mark: Double? = nil) throws -> (NSView, [AnyObject]) {
        try hud { $0.showVoice(sentence: sentence, detail: detail, rows: [], owner: .flash, mark: mark) }
    }

    static func guide(withIcons: Bool) throws -> (NSView, [AnyObject]) {
        try hud { hud in
            if withIcons {
                hud.showGuide(keys: ["lode"], rows: [
                    GuideRow(key: "s", label: "Safari", icon: icon("/Applications/Safari.app")
                        ?? icon("/System/Cryptexes/App/System/Applications/Safari.app")),
                    GuideRow(key: "e", label: "Mail", icon: icon("/System/Applications/Mail.app")),
                    GuideRow(key: "n", label: "Notes", icon: icon("/System/Applications/Notes.app")),
                    GuideRow(key: "d", label: "→ a b"),
                ])
            } else {
                hud.showGuide(mark: "arrow.up.and.down", keys: ["lode", "`"], rows: [
                    GuideRow(key: "j k", label: "Down · up"), GuideRow(key: "d u", label: "Half-page down · up"),
                    GuideRow(key: "/", label: "Aim at a word"), GuideRow(keys: ["esc"], label: "Leave", lit: true),
                ])
            }
        }
    }

    // MARK: - Feedback and the walk

    static func feedback(_ index: Int) throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(Stage.screen(1400, 900)) {
            try GalleryHost.surface(made: { [FeedbackController.preview(index)] },
                                    where: { $0 is KeyablePanel })
        }
    }

    static func walk(_ index: Int) throws -> (NSView, [AnyObject]) {
        var config = Config()
        config.graph = Stage.graph()
        return try withPresentationFrame(Stage.screen(1400, 900)) {
            try GalleryHost.surface(made: { [WalkController.preview(index, config: config)] })
        }
    }

    static var shots: [GalleryShot] {
        func chrome(_ surface: String, _ state: String, looks: [GalleryLook] = GalleryLook.all,
                    _ make: @escaping () throws -> (NSView, [AnyObject])) -> GalleryShot {
            var shot = GalleryShot(surface: surface, state: state, looks: looks) { _ in try make() }
            shot.trim = true
            return shot
        }
        // The quiet phase draws receded at once, so its picture is made with
        // Eye comfort on, as the app has it by default, and checked receded.
        func quietChip(_ surface: String, _ state: String,
                       _ make: @escaping () throws -> (NSView, [AnyObject])) -> GalleryShot {
            var shot = chrome(surface, state, make)
            shot.receded = true
            return shot
        }
        let slack = icon("/Applications/Safari.app") ?? icon("/System/Applications/Notes.app")
        func state(_ mode: ModePill.Mode, listening: Bool = false, text: String? = nil, anchored: String? = nil,
                   offer: ModePill.Offer? = nil) -> ModePill.State {
            ModePill.State(mode: mode, app: "Notes", icon: slack, listening: listening, text: text,
                           anchored: anchored, offer: offer)
        }
        return [
            chrome("pill", "scroll-standing") { try pill(state(.scroll)) },
            chrome("pill", "click-listening") { try pill(state(.click, listening: true)) },
            chrome("pill", "select-typing") { try pill(state(.select, listening: true, text: "thr")) },
            chrome("pill", "select-anchored") { try pill(state(.select, listening: true, anchored: "Threads")) },
            chrome("pill", "editor") { try pill(state(.editor)) },
            chrome("pill", "opening") { try pill(state(.opening)) },
            chrome("pill", "offer") {
                try pill(state(.scroll, offer: .init(key: "⏎", words: "Always scroll here", lit: true)))
            },
            chrome("meeting", "countdown-quiet") { try meeting(startingIn: 4 * 60) },
            chrome("meeting", "lit-now") { try meeting(startingIn: 0) },
            chrome("meeting", "door-seconds") { try meeting(startingIn: 45) },
            quietChip("meeting", "past") { try meeting(startingIn: -3 * 60) },
            chrome("meeting", "long-title") {
                try meeting(startingIn: 4 * 60,
                            title: "Quarterly planning review with the platform, design and finance leads")
            },
            chrome("draft", "speaking-ghost") { try draft(0) },
            chrome("draft", "editing-normal") { try draft(1) },
            chrome("draft", "editor-lens-marked") { try lens() },
            chrome("coach", "one-app") { try coach(false) },
            chrome("coach", "two-apps") { try coach(true) },
            chrome("coach", "record-wraps") { try coachWrapped() },
            chrome("note", "flash-fact-and-way") {
                try note("✕ No profile named Work in Brave\nTry [lode][,] to see the profiles")
            },
            chrome("note", "flash-with-icon") { try note("Layout undone", icon: "/System/Applications/Notes.app") },
            chrome("note", "flash-held-warning") { try note("⚠ Accessibility is off\nPress [lode][,] to turn it on") },
            chrome("note", "voice-lit-mark") {
                try voice("Lodestar 0.51.1 is on its way", detail: "Taking it now, 60% downloaded", mark: 0.6)
            },
            chrome("guide", "chain-with-icons") { try guide(withIcons: true) },
            chrome("guide", "keys-no-icons-lit-row") { try guide(withIcons: false) },
            chrome("feedback", "writing") { try feedback(45) },
            chrome("feedback", "writing-reply-typed") { try feedback(48) },
            chrome("feedback", "saved-not-sent") { try feedback(46) },
            chrome("feedback", "thanks") { try feedback(47) },
            chrome("walk", "welcome-tiles-none-chosen") { try walk(0) },
            chrome("walk", "welcome-tile-chosen") { try walk(1) },
            chrome("walk", "permission") { try walk(2) },
            chrome("walk", "step") { try walk(5) },
            chrome("walk", "lesson-card") { try walk(10) },
        ]
    }
}
