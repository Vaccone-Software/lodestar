import Foundation
import Stoic
import StoicHTTP

/// The daily count: once a UTC day, a Mac that was used tells the site so,
/// and the site adds one to that day's counters. It is the only thing that
/// leaves the Mac to say Lodestar is in use, and it is built so that it can
/// say nothing else.
///
/// **What is sent** is three words and nothing more: the Lodestar version,
/// the update channel this Mac follows and how long ago Lodestar first ran
/// here, as one of five coarse buckets. No macOS version, no date (the site
/// dates it on arrival) and no identifier of any kind. The Mac remembers
/// the last day it sent, so the site never needs to tell one Mac from
/// another to count each once, and it is never given the means to. The
/// site keeps each word as its own counter, never the combination, so no
/// stored row is one Mac.
///
/// **When** is the first deliberate use of a UTC day (a lode gesture, a
/// dictation landed, an editor fix taken), from a hand rather than a posted
/// event, and then a random wait of up to two hours, so the ping does not
/// say when someone sat down. A Lodestar that is merely running at login
/// is not counted.
///
/// **Said** once, quietly: a sentence on the first-launch window
/// (`welcomeNote`) for a new Mac, and the release notes for one that
/// updates into it. There is no notice on the glass and nothing to dismiss.
///
/// **Never** with the switch off (`app.daily-count`, a switch of its own,
/// apart from updates), and never from a test run, a debug or development
/// build, or a copy that is not the installed app.
///
/// Pure: the record, the decisions and the request. The app keeps the
/// timer and the network (`DailyCountController`).
public enum DailyCount {
    /// The site's door for the count. The header is proof of origin, not a
    /// secret: a crawler posting without it is turned away.
    public static let path = "/api/count"
    public static let originHeader = ("x-lodestar-count", "1")

    /// How long one try may take.
    public static let attemptTimeout = Duration.seconds(20)

    /// The longest wait between the day's first use and the ping.
    public static let maximumDelay: TimeInterval = 2 * 60 * 60

    /// How recently a hand must have been at the keys for a fix or a
    /// dictation to count as this Mac being used. A lode gesture is a hand
    /// by the tap's own reading and needs no window.
    public static let handWindow: TimeInterval = 5 * 60

    // MARK: - The payload

    /// How long ago Lodestar first ran on this Mac, as coarse as retention
    /// needs and no finer: the day it arrived, the first week, the first
    /// month, the first quarter, and after.
    public enum Age: String, CaseIterable, Codable, Equatable, Sendable {
        case firstDay = "0"
        case firstWeek = "1-6"
        case firstMonth = "7-29"
        case firstQuarter = "30-89"
        case later = "90+"

        /// The bucket for whole days since the first run. A first run in
        /// the future (a clock set back) is the first day.
        public init(days: Int) {
            switch days {
            case ..<1: self = .firstDay
            case 1...6: self = .firstWeek
            case 7...29: self = .firstMonth
            case 30...89: self = .firstQuarter
            default: self = .later
            }
        }

        public init(installedAt: Date, now: Date) {
            self.init(days: Int((now.timeIntervalSince(installedAt) / 86_400).rounded(.down)))
        }
    }

    /// Everything the site is told.
    public struct Payload: Equatable, Sendable {
        public var channel: Updater.Channel
        public var age: Age
        /// The plain dotted version, `0.54.25`: no `v`, no build suffix.
        public var version: String

        public init(channel: Updater.Channel, age: Age, version: String = Lodestar.version) {
            self.channel = channel
            self.age = age
            self.version = version
        }

        /// `{"age":"7-29","channel":"stable","version":"0.54.25"}`: sorted
        /// keys, so the same count is the same bytes, and exactly these
        /// three.
        public var body: Data {
            let object = ["channel": channel.rawValue, "age": age.rawValue, "version": version]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        public var httpRequest: HTTPRequest {
            .post(DailyCount.path, body: [UInt8](body), contentType: "application/json",
                  headers: [DailyCount.originHeader.0: DailyCount.originHeader.1])
        }
    }

    /// The client the count goes through: the site, one try of twenty
    /// seconds. The controller's schedule is the retrying.
    public static func client(transport: any HTTPTransport = URLSessionTransport()) -> HTTPClient {
        var policy = HTTPPolicy.singleAttempt
        policy.attemptTimeout = attemptTimeout
        return HTTPClient(base: Feedback.site, policy: policy, transport: transport, label: "daily-count")
    }

    // MARK: - The answer

    /// What a try came to.
    public enum Outcome: Equatable, Sendable {
        /// The site counted it: exactly a 204.
        case counted
        /// The site refused it for good (a 400): a bug in what was sent,
        /// and sending it again would only be refused again.
        case refused
        /// Nothing is known to have been counted: the network, the site,
        /// or an answer that is not the site's (a wifi sign-in page answers
        /// 200 to everything). Tried again later the same day.
        case later
    }

    public static func classify(_ response: HTTPResponse) -> Outcome {
        response.status == 204 ? .counted : .later
    }

    public static func classify(_ error: any Error) -> Outcome {
        if case HTTPError.status(400, _, _, _, _)? = error as? HTTPError { return .refused }
        return .later
    }

    /// A minute, five, then half an hour, each drawn between its half and
    /// its whole; after that the day goes uncounted. Bounded on purpose: a
    /// count that cannot reach the site is not worth a Mac's attention.
    public static func retryDelay(afterFailures failures: Int, random: RandomSource = .system) -> TimeInterval? {
        let delays: [TimeInterval] = [60, 300, 1800]
        guard failures >= 1, failures <= delays.count else { return nil }
        let delay = delays[failures - 1]
        var stepper = Schedule.fixed(.seconds(delay)).jittered(.equal)
            .makeStepper(random: random.generator(discriminator: UInt64(failures)))
        guard let jittered = stepper.next(elapsed: .zero) else { return delay }
        return TimeInterval(jittered.components.seconds) + TimeInterval(jittered.components.attoseconds) / 1e18
    }

    // MARK: - Who may count

    /// Whether this copy of Lodestar may count at all: the installed,
    /// released app and nothing else. A test run, a debug build (`swift
    /// build`), a development build (`LodestarDevelopment` in its
    /// Info.plist) and a copy run from anywhere but Applications are the
    /// author's and the machines', never a person using Lodestar.
    public static func eligible(debug: Bool, testRun: Bool, development: Bool, installed: Bool) -> Bool {
        !debug && !testRun && !development && installed
    }

    /// The real answer for this process.
    public static func thisProcessIsEligible(bundle: Bundle = .main) -> Bool {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return eligible(debug: debug, testRun: TestRun.active,
                        development: bundle.object(forInfoDictionaryKey: "LodestarDevelopment") as? Bool == true,
                        installed: Updater.isInstalled(bundlePath: bundle.bundlePath, home: Paths.userHome.path))
    }

    // MARK: - The record

    /// What the Mac remembers about the count, in the machine-owned state.
    /// Every field is about this Mac and none of it is sent.
    public struct Record: Codable, Equatable, Sendable {
        /// When Lodestar first ran on this Mac, as far as the Mac can tell.
        public var installedAt: Date?
        /// The last UTC day counted, `yyyy-MM-dd`.
        public var lastSentDay: String?
        /// The day waiting to be counted, and when.
        public var pending: Pending?

        public init(installedAt: Date? = nil, lastSentDay: String? = nil, pending: Pending? = nil) {
            self.installedAt = installedAt
            self.lastSentDay = lastSentDay
            self.pending = pending
        }

        /// Two records of one Mac, as a launch after a downgrade finds them:
        /// the first run was when it first was, the last day counted is the
        /// later one, and a pending day is the newer side's unless that day
        /// was already counted.
        public func merging(newer: Record) -> Record {
            var out = Record()
            out.installedAt = [installedAt, newer.installedAt].compactMap { $0 }.min()
            out.lastSentDay = [lastSentDay, newer.lastSentDay].compactMap { $0 }.max()
            let pending = newer.pending ?? pending
            out.pending = pending.flatMap { $0.day == out.lastSentDay ? nil : $0 }
            return out
        }
    }

    public struct Pending: Codable, Equatable, Sendable {
        public var day: String
        public var due: Date

        public init(day: String, due: Date) {
            self.day = day
            self.due = due
        }
    }

    /// The UTC day a moment falls in, `yyyy-MM-dd`: one calendar for every
    /// Mac, so a day is the same day wherever it is counted.
    public static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// When Lodestar first ran here: the earliest of what the Mac kept
    /// (the data folder's creation, the logbook's first entry), never later
    /// than now. Nothing kept means now.
    public static func installedAt(evidence: [Date?], now: Date) -> Date {
        let known = evidence.compactMap { $0 }.filter { $0 > Date(timeIntervalSince1970: 0) && $0 <= now }
        return known.min() ?? now
    }

    // MARK: - The decisions

    /// What a use asks of the app.
    public enum Step: Equatable, Sendable {
        /// Nothing: counting is off, already done today or already waiting.
        case nothing
        /// Today waits to be counted, at this moment.
        case schedule(Pending)
    }

    /// The decision for one deliberate use at `now`. `delay` is the random
    /// wait, drawn by the caller, clamped to the two hours.
    public static func use(_ record: Record, now: Date, enabled: Bool, delay: TimeInterval) -> Step {
        guard enabled else { return .nothing }
        let today = day(of: now)
        if record.lastSentDay == today || record.pending?.day == today { return .nothing }
        let wait = min(max(delay, 0), maximumDelay)
        return .schedule(Pending(day: today, due: now.addingTimeInterval(wait)))
    }

    /// What is left of a pending day at `now`: kept while it is still its
    /// own day, and dropped once the day has passed, uncounted. A day is
    /// one day's count, never a later day's.
    public static func live(_ pending: Pending?, now: Date) -> Pending? {
        guard let pending, pending.day == day(of: now) else { return nil }
        return pending
    }

    /// Whether a pending day goes now.
    public static func isDue(_ pending: Pending?, now: Date) -> Bool {
        guard let pending = live(pending, now: now) else { return false }
        return now >= pending.due
    }

    // MARK: - Words

    /// The one sentence a new Mac is told, quietly, at the foot of the
    /// first-launch window. A Mac that updates into the count is told by
    /// the release notes.
    public static let welcomeNote =
        "Once a day Lodestar tells its site that this Mac used it, with no ID. Turn it off in Settings."

    /// The switch's row in Settings.
    public static let settingsTitle = "Daily count"
    public static let settingsDetail =
        "Once a day, tells the Lodestar site that this Mac used Lodestar, with its version, the update channel and how long ago it was installed. No ID and no tracker"
}
