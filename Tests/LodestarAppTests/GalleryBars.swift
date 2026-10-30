import AppKit
import ApplicationServices
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A reader that answers for windows nobody owns: element `n` is window `n`,
/// with the title the script gives it.
final class GalleryReader: WindowAXReader, @unchecked Sendable {
    var titles: [pid_t: String] = [:]
    static func element(_ n: Int32) -> AXUIElement { AXUIElementCreateApplication(900_000 + n) }
    private func number(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid - 900_000
    }
    func windowID(of element: AXUIElement) -> CGWindowID? { CGWindowID(number(element)) }
    func reading(of element: AXUIElement) -> WindowModel.Reading? {
        .init(title: titles[number(element)] ?? "", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
              isMinimized: false, subrole: "AXStandardWindow")
    }
    func title(of element: AXUIElement) -> String? { titles[number(element)] }
    func frame(of element: AXUIElement) -> CGRect? { CGRect(x: 0, y: 0, width: 800, height: 600) }
    func windows(of pid: pid_t) -> [AXUIElement]? { [] }
    func focusedWindow(of pid: pid_t) -> AXUIElement? { nil }
}

enum GalleryBars {
    /// The launcher choosing among one app's windows.
    static func chooser(look: GalleryLook) throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(Stage.screen) { try chooserSurface(look: look) }
    }

    private static func chooserSurface(look: GalleryLook) throws -> (NSView, [AnyObject]) {
        let reader = GalleryReader()
        let titles = ["Pull requests · vaccone-software/lodestar", "Lodestar — Design languages",
                      "Inbox (3) — personal", "Settings"]
        for (index, title) in titles.enumerated() { reader.titles[Int32(index + 1)] = title }
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        let pid = finder?.processIdentifier ?? 1
        let model = WindowModel(reader: reader, appLookup: { _ in .init(pid: pid, name: "Brave Browser", bundleID: "com.brave.Browser") })
        model.frontmostApp = { nil }
        for index in 1...titles.count {
            model.receiveForTesting(kAXWindowCreatedNotification, element: GalleryReader.element(Int32(index)), pid: pid)
        }
        let deadline = Date().addingTimeInterval(3)
        while model.windows.count < titles.count, Date() < deadline { GalleryHost.settle(0.02) }
        let world = GalleryWorld(model: model)
        var made: SearcherController?
        let (view, keep) = try GalleryHost.surface(made: {
            made = SearcherController(appIndex: world.appIndex, actions: world.actions, model: model)
            made?.showWindowChooser(pid: pid, appName: "Brave Browser")
            return [made as Any as AnyObject, world, model, reader]
        })
        return (view, keep + [made as Any as AnyObject])
    }

    private static let askConfig: Config = {
        let json = """
        {"web": {"links": {"docs": {"url": "developer.apple.com/documentation", "profile": "brave:Work"},
                           "hn": {"url": "news.ycombinator.com"}},
                 "routes": {"github.com": "brave:Work"}, "fallback": "brave:Personal"}}
        """
        var problems: [String] = []
        let tree = (try? Json.parse(json)) ?? [:]
        return Config.build(from: tree, problems: &problems)
    }()

    static func ask(query: String) throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(Stage.screen) {
            try GalleryHost.surface(made: {
                [WebBarController.preview(query: query, config: askConfig)]
            }, where: { $0 is KeyablePanel })
        }
    }

    static func commands(query: String, mixed: Bool) throws -> (NSView, [AnyObject]) {
        let dummy = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func item(_ path: [String], _ shortcut: String? = nil) -> MenuItems.Item {
            MenuItems.Item(element: dummy, path: path, shortcut: shortcut)
        }
        let menus = Commands.rows(menus: [
            item(["Edit", "Paste"], "⌘V"), item(["Edit", "Paste and Match Style"], "⌥⇧⌘V"),
            item(["Format", "Font", "Paste Style"], "⌥⌘V"), item(["File", "Pin Note"]),
            item(["File", "Page Setup…"], "⇧⌘P"), item(["File", "Export as PDF…"]),
        ], app: "Notes")
        var rows = menus
        if mixed {
            // The second feed, when it lands: a system verb among the menus.
            rows.insert(Commands.Row(verb: menus[0].verb, title: "Paste history", crumb: "Keep", shortcut: nil,
                                     source: "system", searchKey: "Paste history"), at: 1)
        }
        return try withPresentationFrame(Stage.screen) {
            try GalleryHost.surface(made: { [CommandsBarController.preview(query: query, rows: rows)] },
                                    where: { $0 is KeyablePanel })
        }
    }

    static var shots: [GalleryShot] {
        func bar(_ surface: String, _ state: String,
                 _ make: @escaping (GalleryLook) throws -> (NSView, [AnyObject])) -> GalleryShot {
            GalleryShot(surface: surface, state: state, looks: GalleryLook.all, build: make)
        }
        return [
            bar("launcher", "window-chooser") { try chooser(look: $0) },
            bar("ask", "empty") { _ in try ask(query: "") },
            bar("ask", "typed-address") { _ in try ask(query: "github.com/vaccone-software") },
            bar("commands", "typed-pa") { _ in try commands(query: "pa", mixed: false) },
            bar("commands", "source-chips-mixed-feeds") { _ in try commands(query: "pa", mixed: true) },
        ]
    }
}
