import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Settings: the overview, every place, the pages behind them and a search,
/// drawn without the window being shown.
enum GallerySettings {
    static func controller() -> SettingsController {
        let settings = SettingsController()
        var config = Config()
        config.graph = Stage.graph()
        settings.config = config
        settings.machineState = {
            var state = SettingsModel.MachineState(
                accessibility: "Granted", screenRecording: "Not asked yet", calendars: "Granted",
                browserRole: "Brave holds the role.", savedBrowser: "Brave  (com.brave.Browser)",
                detectedProfiles: [
                    .init(browser: "brave", browserLabel: "Brave", name: "Personal"),
                    .init(browser: "brave", browserLabel: "Brave", name: "Work"),
                    .init(browser: "chrome", browserLabel: "Chrome", name: "Default"),
                ])
            state.inputDevices = ["MacBook Pro Microphone", "CalDigit Thunderbolt 3 Audio"]
            state.defaultInput = "MacBook Pro Microphone"
            state.keyboards = [.init(id: "1452:834:0", name: "Apple Internal Keyboard", builtIn: true, attached: true),
                               .init(id: "1:2:3", name: "Moonlander", builtIn: false, attached: true)]
            state.editorEngines = ["spelling", "minimal", "standard", "full"]
            state.editorEngineLabels = ["Spelling · no download", "Minimal · built into macOS",
                                        "Standard · 2.6 GB download · holds 4 GB", "Full · 11.0 GB download · holds 20 GB"]
            state.draftModelLabels = ["Apple only", "Standard · Parakeet and Gemma 4 E2B",
                                      "Full · Qwen3-ASR and Gemma 4 E2B", "Max · needs 64 GB"]
            state.draftModelsUnavailable = ["max"]
            state.editorModelStatus = "Standard is ready"
            state.isDark = Tone.systemDark
            return state
        }
        settings.attachedKeyboards = { settings.machineState().keyboards }
        settings.appChoices = { [("Safari", "com.apple.Safari"), ("Notes", "com.apple.Notes")] }
        return settings
    }

    /// The window as it stands once opened, which is the size Settings is.
    static func window(look: GalleryLook, _ stage: @escaping (SettingsController) -> Void) throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(Stage.screen) {
            try GalleryHost.surface(made: {
                let settings = controller()
                stage(settings)
                return [settings]
            }, settle: 0.05, where: { $0 is KeyablePanel }, frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
        }
    }

    static var shots: [GalleryShot] {
        func settings(_ state: String, looks: [GalleryLook] = GalleryLook.all,
                      _ stage: @escaping (SettingsController) -> Void) -> GalleryShot {
            GalleryShot(surface: "settings", state: state, looks: looks) { look in
                try window(look: look, stage)
            }
        }
        var all: [GalleryShot] = [settings("overview") { $0.renderForTesting(place: nil) }]
        for (index, name) in SettingsModel.placeNames.enumerated() {
            all.append(settings(name.lowercased(), looks: GalleryLook.all) {
                $0.renderForTesting(place: index)
            })
        }
        for page in [SettingsModel.keyboardsPage, SettingsModel.wordsPage, SettingsModel.historyPage] {
            all.append(settings("page-" + page.lowercased()) {
                $0.renderForTesting(place: SettingsModel.placeIndex(page == SettingsModel.wordsPage ? "Write" : "General"))
                $0.openForTesting(page: page)
            })
        }
        all.append(settings("landing-row") {
            $0.landForTesting(place: SettingsModel.placeIndex("Keep")!, row: 1)
        })
        all.append(settings("search-empty") {
            $0.renderForTesting(place: nil)
            $0.searchForTesting("")
        })
        all.append(settings("search-clipboard") {
            $0.renderForTesting(place: nil)
            $0.searchForTesting("clipboard")
        })
        return all
    }
}
