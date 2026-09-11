#if DEBUG
import AppKit
import LodestarCore

/// The surfaces of the next sheet, staged through the real code paths so
/// the sheet shows what ships. Debug-only; nothing here runs in the app.
enum NextSheet {
    private static var held: [AnyObject] = []

    private static func env(_ key: String, _ fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }

    private static func icon(_ path: String) -> NSImage? {
        FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    static func run(_ variant: Int) {
        switch variant {
        case 100: openingPill()
        case 101: meeting()
        case 102: accessibility()
        case 103: lesson()
        case 104: chainGuide()
        case 105: askBar(sheet: false)
        case 106: askBar(sheet: true)
        case 107: pillSheet()
        default: break
        }
    }

    // 100: OPEN=slack|profile. The pill in its opening mode.
    private static func openingPill() {
        let pill = ModePill()
        if env("OPEN", "slack") == "profile" {
            pill.show(.init(mode: .opening, app: "Brave · Work",
                            icon: icon("/Applications/Brave Browser.app"), listening: false, text: nil))
        } else {
            pill.show(.init(mode: .opening, app: "Slack",
                            icon: icon("/Applications/Slack.app"), listening: false, text: nil))
        }
        held.append(pill)
    }

    // 101: MEETING=minutes|seconds|now|ago, through the controller's own
    // evaluate and render.
    private static func meeting() {
        let offset: TimeInterval
        switch env("MEETING", "minutes") {
        case "seconds": offset = 45
        case "now": offset = 0
        case "ago": offset = -3 * 60
        default: offset = 4 * 60
        }
        held.append(MeetingController.preview(0, startingIn: offset))
    }

    // 102: the boot ask, exactly as the app delegate words it.
    private static func accessibility() {
        let hud = HUD()
        hud.showVoice(sentence: AppDelegate.accessibilityNote, detail: AppDelegate.accessibilityDetail,
                      rows: [], owner: .flash)
        held.append(hud)
    }

    // 103: LESSON=inside|web|draft|select|commands|scroll|clipboard|sheet|done,
    // on the walk's own card.
    private static func lesson() {
        let which = env("LESSON", "scroll")
        let lessons = Curriculum.order.map(\.lesson)
        let index = which == "done" ? 16 : 8 + (lessons.firstIndex { $0.rawValue == which } ?? 0)
        held.append(WalkController.preview(index))
    }

    // 104: CHAIN=root|deeper|breath, on the HUD.
    private static func chainGuide() {
        let hud = HUD()
        switch env("CHAIN", "root") {
        case "deeper":
            hud.showGuide(keys: ["lode", "D"], rows: [
                GuideRow(key: "G", label: "Ghostty", icon: icon("/Applications/Ghostty.app")),
                GuideRow(key: "X", label: "Xcode", icon: icon("/Applications/Xcode.app")),
                GuideRow(key: "F", label: "Figma", icon: icon("/Applications/Figma.app"))])
        case "breath":
            hud.showGuide(mark: BarTheme.breathSymbol, keys: ["lode", "'"], rows: [
                GuideRow(key: "'", label: "Update the latest breath"),
                GuideRow(key: "W", label: "Ghostty · Brave"),
                GuideRow(key: "R", label: "Xcode · Ghostty · Slack")])
        default:
            hud.showGuide(keys: ["lode"], rows: [
                GuideRow(key: "W", label: "Safari", icon: icon("/Applications/Safari.app")),
                GuideRow(key: "E", label: "Mail", icon: icon("/System/Applications/Mail.app")),
                GuideRow(key: "N", label: "Notes", icon: icon("/System/Applications/Notes.app")),
                GuideRow(key: "D", label: "→ development")])
        }
        held.append(hud)
    }

    // 105: Ask, as it ships; 106: grown to hold its keys.
    // ANIMATE=1 delays the unfold so a recording can catch it.
    private static func askBar(sheet: Bool) {
        let json = """
        { "web": { "links": { "docs": "developer.apple.com/documentation" },
                   "routes": { "github.com": "default" }, "fallback": "default" } }
        """
        var problems: [String] = []
        let tree = (try? Json.parse(json)) ?? [:]
        let config = Config.build(from: tree, problems: &problems)
        let bar = WebBarController.preview(query: "github.com/vaccone-software", config: config)
        held.append(bar)
        guard sheet else { return }
        let delay: TimeInterval = env("ANIMATE", "") == "1" ? 1.5 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            bar.toggleKeys(HotkeyEngine.askSections)
        }
    }

    // 107: the scroll pill grown to hold its keys.
    private static func pillSheet() {
        let pill = ModePill()
        pill.show(.init(mode: .scroll, app: "Slack", icon: icon("/Applications/Slack.app"),
                        listening: false, text: nil))
        held.append(pill)
        let sections = [CheatSheet.Section(header: "Scroll", rows: [
            GuideRow(key: "J K", label: "Down · up"),
            GuideRow(key: "D U", label: "Half a page down · up"),
            GuideRow(key: "G G", label: "Top"),
            GuideRow(key: "⇧G", label: "Bottom"),
            GuideRow(key: "/", label: "Scroll where a word is"),
            GuideRow(key: "esc", label: "Leave"),
        ]), HotkeyEngine.everywhereSection]
        let delay: TimeInterval = env("ANIMATE", "") == "1" ? 1.5 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            pill.toggleKeys(sections)
        }
    }
}
#endif
