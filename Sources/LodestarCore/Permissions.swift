import ApplicationServices

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
}
