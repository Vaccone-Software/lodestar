import Foundation

/// What Safari's accessibility tree says about its profiles, read as text.
/// Measured on Safari 27.2 (FINDINGS, and the 2026-11-28 probes): File ▸
/// New Window holds one item per profile with a stable identifier
/// `New<Name>Window?isDefaultProfile=true|false`; a profile's window is
/// titled "<Profile> — <page>"; tabs are `AXTabButton`s whose identifier
/// carries `isActive=true` on the one in front, and the address field is a
/// child of that tab.
public enum SafariProfiles {
    public static let addressFieldID = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    public static let newTabMenuID = "NewTab"
    public static let tabButtonSubrole = "AXTabButton"

    /// The separator Safari puts between the profile and the page.
    static let titleSeparator = " — "

    public struct MenuProfile: Equatable, Sendable, Codable {
        public let name: String
        public let identifier: String
        public let isDefault: Bool

        public init(name: String, identifier: String, isDefault: Bool) {
            self.name = name
            self.identifier = identifier
            self.isDefault = isDefault
        }
    }

    /// The profile a New Window menu item opens, or nil for any other item.
    public static func menuProfile(fromIdentifier identifier: String) -> MenuProfile? {
        let marker = "Window?isDefaultProfile="
        guard identifier.hasPrefix("New"), let range = identifier.range(of: marker) else { return nil }
        let raw = String(identifier[identifier.index(identifier.startIndex, offsetBy: 3)..<range.lowerBound])
        let name = raw.removingPercentEncoding ?? raw
        guard !name.isEmpty else { return nil }
        let flag = identifier[range.upperBound...].prefix { $0 != "&" }
        return MenuProfile(name: name, identifier: identifier, isDefault: flag == "true")
    }

    /// Every profile among a menu's item identifiers, in menu order, once each.
    public static func menuProfiles(fromIdentifiers identifiers: [String]) -> [MenuProfile] {
        var seen = Set<String>()
        return identifiers.compactMap(menuProfile(fromIdentifier:)).filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// The profile a window belongs to, by its title: the longest listed
    /// name the title begins with, followed by Safari's separator. The
    /// longest, so a profile named "Work — Old" is never read as "Work"; and
    /// only listed names, so a private window ("Untitled, Private
    /// Browsing", in whatever language) or a page whose own title has a
    /// dash belongs to no profile.
    public static func profile(ofTitle title: String, among names: [String]) -> String? {
        let lowered = title.lowercased()
        return names
            .filter { lowered.hasPrefix($0.lowercased() + titleSeparator) }
            .max { $0.count < $1.count }
    }

    /// Whether a tab button's identifier marks the tab in front.
    public static func isActiveTab(identifier: String?) -> Bool {
        identifier?.contains("isActive=true") ?? false
    }

    /// A URL Lodestar may type into Safari's address field. The field runs
    /// a `javascript:` URL in the page in front, which no link should ever
    /// get to do by being clicked somewhere else.
    public static func mayType(_ url: String) -> Bool {
        !url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("javascript:")
    }
}
