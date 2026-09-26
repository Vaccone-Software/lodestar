import ApplicationServices
import Darwin

public enum Permissions {
    /// Whether this process (via its responsible app — the terminal, when run
    /// from a shell) is trusted for Accessibility.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Like `isTrusted`, but asks macOS to show the grant prompt when not.
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Whether this account is an administrator, the `admin` group (80)
    /// among the process's groups. Turning Accessibility on needs an
    /// administrator's password, so an account without one is told before
    /// it goes looking, and nothing is asked to find this out.
    public static var isAdministrator: Bool {
        isAdministrator(groups: currentGroups())
    }

    static func isAdministrator(groups: [gid_t]) -> Bool {
        groups.contains(80)
    }

    private static func currentGroups() -> [gid_t] {
        let count = getgroups(0, nil)
        guard count > 0 else { return [] }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let filled = getgroups(count, &groups)
        return filled > 0 ? Array(groups.prefix(Int(filled))) : []
    }
}
