import Foundation

/// Pure web-bar routing logic: what the typed text is, and which profile it
/// belongs to. No UI, no browser — testable in isolation.
public enum WebRouting {
    /// Does this input look like a destination rather than a query?
    /// A single token containing a dot (youtube.com, linear.app/team) or an
    /// explicit scheme counts; anything with spaces is a query.
    public static func isDomainLike(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return true
        }
        guard let host = trimmed.split(separator: "/").first else { return false }
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    /// Normalize typed input into an openable URL.
    public static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://" + trimmed
    }

    /// Resolve a routing table against an input: case-insensitive substring
    /// match, longest pattern wins — deterministic without ordering.
    public static func route(_ input: String, routes: [String: String]) -> String? {
        let lowered = input.lowercased()
        var best: (pattern: String, value: String)?
        for (pattern, value) in routes {
            guard lowered.contains(pattern.lowercased()) else { continue }
            if best == nil || pattern.count > best!.pattern.count {
                best = (pattern, value)
            }
        }
        return best?.value
    }

    /// Build a search URL: `%s` is replaced with the encoded query, or the
    /// encoded query is appended when no placeholder exists.
    public static func searchURL(template: String, query: String) -> String {
        let encoded = query.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26") ?? ""
        if template.contains("%s") {
            return template.replacingOccurrences(of: "%s", with: encoded)
        }
        return template + encoded
    }
}
