import Foundation

/// The Reversed wheels page: one switch per source Lodestar has heard turn
/// a wheel or has been told to turn, and nothing else on the Mac touched.
extension SettingsModel {
    public static let wheelsPage = "Reversed wheels"
    /// The config path of the table the page's switches write, which a
    /// source's id follows (an id may hold dots, so it is never split).
    public static let wheelsPath = "mice.reversed-wheels"

    /// One source the page lists, as the window sees it.
    public struct Wheel: Equatable {
        /// The config's key: the roster's id for a mouse, `app:<bundle id>`
        /// for an app that posts a mouse's scrolls.
        public let id: String
        public let name: String
        /// Plugged in, or running, now.
        public let present: Bool

        public init(id: String, name: String, present: Bool) {
            self.id = id
            self.name = name
            self.present = present
        }
    }

    /// A page row's source, with what its row says about it.
    public struct WheelEntry: Equatable {
        public let id: String
        /// What it is called in a list: a mouse by its name, an app as the
        /// mice that scroll through it.
        public let title: String
        /// The name the config keeps for it.
        public let name: String
        public let present: Bool
        public let ticked: Bool
        public var isApp: Bool { WheelSource.bundleID(of: id) != nil }
    }

    /// Every source on the page: the ones heard this launch and the ones
    /// ticked, a ticked one that has gone listed all the same under the
    /// name the config kept. Mice first, then the apps, each by name.
    public static func wheelSources(config: Config, machine: MachineState) -> [WheelEntry] {
        var byID: [String: Wheel] = Dictionary(machine.wheels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, name) in config.reversedWheels where byID[id] == nil {
            byID[id] = Wheel(id: id, name: name, present: false)
        }
        return byID.values.map { wheel in
            let isApp = WheelSource.bundleID(of: wheel.id) != nil
            return WheelEntry(id: wheel.id, title: isApp ? "Mice through \(wheel.name)" : wheel.name,
                              name: wheel.name, present: wheel.present,
                              ticked: config.reversedWheels[wheel.id] != nil)
        }
        .sorted { ($0.isApp ? 1 : 0, $0.title, $0.id) < ($1.isApp ? 1 : 0, $1.title, $1.id) }
    }

    /// The Input place's row for the page: what is ticked, by name.
    static func wheelsSummary(config: Config, machine: MachineState) -> String {
        let ticked = wheelSources(config: config, machine: machine).filter(\.ticked).map(\.title)
        return ticked.isEmpty ? "None" : ticked.joined(separator: ", ")
    }

    static func wheelsSection(config: Config, machine: MachineState) -> Section {
        let allowed = granted(machine.inputMonitoring)
        let sources = wheelSources(config: config, machine: machine)
        var rows = sources.map { source -> Row in
            let detail: String
            if !allowed {
                detail = "Needs Input Monitoring"
            } else if !source.present {
                detail = source.isApp ? "Not running" : "Not connected"
            } else {
                detail = source.ticked ? "Its wheel scrolls the other way" : "Its wheel scrolls the way the Mac does"
            }
            return Row(title: source.title, path: "\(wheelsPath).\(source.id)", control: .toggle(source.ticked),
                       detail: detail, isDefault: !source.ticked, dimmed: !allowed, group: "Mice")
        }
        if rows.isEmpty {
            rows = [Row(title: "No mouse heard",
                        control: .readout("Turn the wheel of a mouse to list it here", sub: nil),
                        detail: allowed ? nil : "Needs Input Monitoring", group: "Mice")]
        }
        rows.append(permission("Input Monitoring", state: machine.inputMonitoring,
                               detail: "Hearing which mouse turned a wheel", pane: "input-monitoring",
                               group: "Permission"))
        return Section(name: wheelsPage, rows: rows, parent: "Input", picture: "place-keys",
                       sentence: "A mouse wheel that scrolls the other way, while the trackpad keeps the Mac's setting",
                       note: "A scroll is turned only when the wheel that made it is heard, so nothing is guessed")
    }
}
