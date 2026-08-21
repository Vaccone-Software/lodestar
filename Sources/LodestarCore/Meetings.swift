import Foundation

/// Meetings: the calendar's next join, offered at the door. Pure logic
/// only — which link is a meeting, which profile it lands in and which
/// rule decided that, and which occurrence deserves the chip right now.
/// EventKit stays in the shell, exactly as AppKit does everywhere else:
/// this file must compile and test with no calendar on the machine.
///
/// The profile question is Ask's question one ring further out, and it
/// gains one signal the URL can never carry: a work meeting and a
/// personal meeting on meet.google.com are byte-identical as links, so
/// the calendar the event lives on is the only thing that can tell them
/// apart. That is why the calendar mapping outranks the domain route —
/// the more specific signal wins — and why every answer names its
/// decider, so a surprising profile is never a mystery.
public enum Meetings {
    // MARK: - Providers

    public enum Provider: String, CaseIterable {
        case zoom, meet, teams, webex, facetime

        /// Patterns a meeting join link matches, host-anchored. Kept
        /// deliberately tight: a link to zoom.us/pricing is not a meeting.
        var patterns: [String] {
            switch self {
            case .zoom:
                return [#"https://(?:[\w-]+\.)?(?:zoom\.us|zoomgov\.com)/(?:j|s|w|my)/[\w?=&.\-]+"#]
            case .meet:
                return [#"https://meet\.google\.com/(?:lookup/[\w\-]+|[a-z]{3}-[a-z]{4}-[a-z]{3})[\w?=&.\-]*"#]
            case .teams:
                return [#"https://teams\.(?:microsoft|live)\.com/l/meetup-join/[\w?=&.%\-/]+"#]
            case .webex:
                return [#"https://(?:[\w-]+\.)?webex\.com/(?:meet|join|wbxmjs)/[\w?=&.\-/]+"#]
            case .facetime:
                return [#"https://facetime\.apple\.com/join[\w?=&.#\-/]*"#]
            }
        }
    }

    /// The hosts and app names that mean "a meeting", for the advisor's
    /// evidence gathering. Host matching is suffix-based because Zoom and
    /// Webex live on per-tenant subdomains; app names are what the focus
    /// events record (Zoom's app really is named "zoom.us").
    public static let meetingHostSuffixes = [
        "meet.google.com", "zoom.us", "zoomgov.com", "teams.microsoft.com",
        "teams.live.com", "webex.com", "facetime.apple.com",
    ]

    public static func isMeetingHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return meetingHostSuffixes.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
    }

    public static let meetingApps: Set<String> = [
        "zoom.us", "microsoft teams", "webex", "cisco webex meetings", "facetime",
    ]

    public struct Link: Equatable {
        public let provider: Provider
        public let url: String

        public init(provider: Provider, url: String) {
            self.provider = provider
            self.url = url
        }
    }

    /// The first recognized meeting link across an event's fields, in
    /// order of trust: the URL property, then the location, then the
    /// notes. Location often carries Zoom; Google Calendar's Meet button
    /// stores its link in conference data EventKit never surfaces, so it
    /// arrives in the notes — the reason no single field is enough.
    ///
    /// Within a field, position wins over provider: notes reading "moved
    /// off Zoom, join here: <meet link>" often keep the old link too, and
    /// the one the organizer put first is the one they mean. Provider
    /// declaration order must never decide a meeting.
    public static func sniff(url: String?, location: String?, notes: String?) -> Link? {
        for field in [url, location, notes] {
            guard let field, !field.isEmpty else { continue }
            var earliest: (at: String.Index, link: Link)?
            for provider in Provider.allCases {
                for pattern in provider.patterns {
                    guard let range = field.range(of: pattern, options: .regularExpression)
                    else { continue }
                    if earliest == nil || range.lowerBound < earliest!.at {
                        earliest = (range.lowerBound,
                                    Link(provider: provider, url: String(field[range])))
                    }
                }
            }
            if let earliest { return earliest.link }
        }
        return nil
    }

    // MARK: - Native hand-off

    /// The app a provider's link can open in directly, skipping the
    /// browser's redirect page. The URL is always opened with the target
    /// app named — never a bare LaunchServices dispatch, the same rule
    /// that keeps click routing from looping — and a machine without the
    /// app falls through to the browser path untouched.
    public struct NativeJoin: Equatable {
        public let url: String
        /// Installed-app candidates, preferred first: Teams ships as two
        /// bundle identities (the new client and classic), and a machine
        /// with either should join natively.
        public let bundleIDs: [String]
    }

    public static func nativeJoin(for link: Link) -> NativeJoin? {
        switch link.provider {
        case .zoom:
            // https://sub.zoom.us/j/123?pwd=X → zoommtg://sub.zoom.us/join?confno=123&pwd=X
            guard let components = URLComponents(string: link.url),
                  let host = components.host else { return nil }
            // Zoom for Government is a different client; its links join in
            // the browser rather than misfire in the consumer app.
            guard host == "zoom.us" || host.hasSuffix(".zoom.us") else { return nil }
            let parts = components.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, ["j", "w", "s"].contains(parts[0]) else { return nil }
            var query = "confno=\(parts[1])"
            // The percent-encoded value, verbatim: queryItems decodes, and
            // re-embedding a decoded password corrupts any encoded byte.
            if let pwd = components.percentEncodedQueryItems?
                .first(where: { $0.name == "pwd" })?.value {
                query += "&pwd=\(pwd)"
            }
            return NativeJoin(url: "zoommtg://\(host)/join?\(query)",
                              bundleIDs: ["us.zoom.xos"])
        case .teams:
            // Teams accepts its own https link behind the msteams scheme.
            let stripped = link.url.replacingOccurrences(of: "https://", with: "")
            return NativeJoin(url: "msteams://\(stripped)",
                              bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"])
        case .meet, .webex, .facetime:
            return nil
        }
    }

    // MARK: - Profile resolution

    /// Which rule chose the profile — shown on the chip, because an
    /// inferred answer can change tomorrow and a chosen one cannot.
    public enum Decider: Equatable {
        case calendar(String)
        case route
        case inherited
    }

    /// The calendar mapping, resolved: the calendar's own name first,
    /// then its account's, because the calendar is the more specific of
    /// the two. Nil means unmapped — inherit, and let the web routing
    /// chain answer as it would for any link. Matching is
    /// case-insensitive: config keys are typed by hand.
    public static func mappedProfile(calendar: String?, account: String?,
                                     mappings: [String: String]) -> (profile: String, decider: Decider)? {
        // Tolerant of duplicates: config keys are typed by hand, and two
        // spellings that fold to one key ("Work", "work") must read as a
        // config quirk, never trap the process.
        let lowered = Dictionary(mappings.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { first, _ in first })
        for name in [calendar, account] {
            guard let name, let profile = lowered[name.lowercased()] else { continue }
            return (profile, .calendar(name))
        }
        return nil
    }

    // MARK: - The chip

    /// One calendar occurrence, as the shell's adapter hands it over:
    /// already filtered (declined and all-day events never arrive here),
    /// already sniffed. The key survives recurrence — the same series
    /// tomorrow is a different occurrence, so a dismissal dies with its
    /// instance, never with the series.
    public struct Occurrence: Equatable {
        public let key: String
        public let title: String
        public let start: Date
        public let end: Date
        public let link: Link
        public let calendar: String?
        public let account: String?

        public init(eventID: String, title: String, start: Date, end: Date,
                    link: Link, calendar: String?, account: String?) {
            self.key = "\(eventID)@\(Int(start.timeIntervalSinceReferenceDate))"
            self.title = title
            self.start = start
            self.end = end
            self.link = link
            self.calendar = calendar
            self.account = account
        }
    }

    /// What the chip says about time: counting down, at the door, or how
    /// far in — late joining is the reason the chip lives the meeting out.
    public enum Phase: Equatable {
        case upcoming(minutes: Int)
        case now
        case inProgress(minutes: Int)
    }

    public struct Candidate: Equatable {
        public let occurrence: Occurrence
        public let phase: Phase
    }

    /// The one occurrence worth a chip right now: inside its window
    /// (lead minutes before start, until its end), not dismissed, not
    /// already joined — and when meetings overlap, the one that started
    /// or starts soonest, because one chip at a time is the rule every
    /// surface here obeys.
    public static func candidate(occurrences: [Occurrence], now: Date,
                                 leadMinutes: Int, spent: Set<String>) -> Candidate? {
        let lead = TimeInterval(leadMinutes * 60)
        let live = occurrences.filter { occurrence in
            !spent.contains(occurrence.key)
                && now >= occurrence.start.addingTimeInterval(-lead)
                && now < occurrence.end
        }
        guard let soonest = live.min(by: { $0.start < $1.start }) else { return nil }
        let untilStart = soonest.start.timeIntervalSince(now)
        let phase: Phase
        if untilStart > 30 {
            phase = .upcoming(minutes: max(1, Int((untilStart / 60).rounded())))
        } else if untilStart > -90 {
            phase = .now
        } else {
            phase = .inProgress(minutes: max(1, Int((-untilStart / 60).rounded())))
        }
        return Candidate(occurrence: soonest, phase: phase)
    }

    /// Spent keys worth keeping: anything whose occurrence could still be
    /// on screen. The past prunes itself, so state.json never accretes a
    /// year of dead meetings.
    public static func prune(spent: Set<String>, keeping occurrences: [Occurrence]) -> Set<String> {
        let alive = Set(occurrences.map(\.key))
        return spent.intersection(alive)
    }
}
