import AppKit
import EventKit
import LodestarCore

/// Meetings at the door: the shell around `Meetings` (LodestarCore). This
/// owns the two surfaces and the one system sense — the chip that offers
/// the calendar's next join, the prime card that asks for the calendar
/// permission, and the EventKit adapter feeding occurrences to the core.
/// Every decision about *which* meeting, *when*, and *where it joins*
/// lives in the core; this file draws, fetches, and executes.
///
/// The chip is never key and swallows nothing, exactly like the walk's
/// companion and for the same reason. It appears `lead-minutes` before
/// the start, lives the meeting out (late joining is the point), and is
/// spent by its own join, a dismissal, or the meeting ending — never by
/// a clock of its own.
///
/// Config carries intent; the machine carries authorization. The two
/// meet here: enabled with access not yet asked runs prime-then-prompt,
/// enabled with access denied stays quiet and says why once. That split
/// is what lets both doors — the menu item and the coach's offer — write
/// exactly one config line and nothing else.
final class MeetingController: NSObject {
    var config = Config() {
        didSet { reconcile() }
    }

    // MARK: - Wiring (owned by the app delegate)

    /// Open a meeting URL in a resolved browser profile — Actions.openWeb.
    var openWeb: ((String, BrowserProfile) -> Void)?
    /// The web routing chain, for meetings whose calendar is unmapped.
    var resolveWeb: ((String) -> (profile: BrowserProfile, label: String)?)?
    /// Flip the one config line (used by "not now" on the prime card).
    var setEnabled: ((Bool) -> String?)?
    var observations: ObservationStore?
    /// The walk holds the floor over the chip.
    var suppressed: () -> Bool = { false }
    var loadSpent: () -> Set<String> = { [] }
    var saveSpent: (Set<String>) -> Void = { _ in }

    // MARK: - EventKit

    private let store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var tick: Timer?
    private var occurrences: [Meetings.Occurrence] = []
    /// Occurrences whose chip has been offered, for the observation that
    /// is recorded once per instance rather than once per redraw.
    private var offered: Set<String> = []
    private var primeShownThisBoot = false
    /// A denied grant is reported once, not every reconcile.
    private var reportedDenied = false
    /// One fetch in flight at a time; a storm of change notifications
    /// coalesces into the trailing edge of a one-second debounce.
    private var refreshing = false
    private var pendingRefresh: DispatchWorkItem?
    /// While enabled and unauthorized, watches for the grant to land in
    /// System Settings — the same no-relaunch-dance promise Accessibility
    /// keeps, kept here too.
    private var grantPoll: Timer?
    var flash: ((String) -> Void)?
    /// The chip took the screen. Meetings outrank the coach — that order is
    /// already enforced for chips not yet shown, through `coach.suppressed`
    /// — but the two live on separate panels, so a coach chip already
    /// standing had nothing to tell it to go.
    var onChipShown: () -> Void = {}

    private(set) var current: Meetings.Candidate?

    // MARK: - Surfaces

    /// The chip: floating glass, never key.
    private let panel = Glass.makePanel(level: .floating)
    private let root = NSView()
    /// The prime card: mouse-first and keyable, in the door's family.
    private let prime = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let primeRoot = NSView()
    private static let primeWidth: CGFloat = 440
    private static let chipWidth: CGFloat = 330

    override init() {
        super.init()
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
        prime.level = .modalPanel
        prime.isOpaque = false
        prime.backgroundColor = .clear
        prime.hasShadow = true
        prime.isReleasedWhenClosed = false
        prime.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        prime.contentView = primeRoot
        _ = Glass.installBackdrop(in: primeRoot, cornerRadius: BarTheme.glassRadius)
        prime.onKeyDown = { [weak self] event in
            guard let self, let key = Keys.name(for: Int64(event.keyCode)),
                  self.prime.isVisible, self.prime.isKeyWindow else { return false }
            switch key {
            case "return", "space": self.allowPressed(); return true
            case "escape": self.notNowPressed(); return true
            default: return true
            }
        }
    }

    var chipVisible: Bool { panel.isVisible }

    /// Calendar and account names for the settings picker — ground truth,
    /// never typed. Empty until access is granted.
    func calendarNames() -> [String] {
        guard authorized else { return [] }
        var names = Set<String>()
        for calendar in store.calendars(for: .event) {
            names.insert(calendar.title)
            if let account = calendar.source?.title { names.insert(account) }
        }
        return names.sorted()
    }

    // MARK: - Authorization

    var authorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    private var authorized: Bool {
        if #available(macOS 14.0, *) { return authorization == .fullAccess }
        return authorization == .authorized
    }

    // MARK: - Reconciling intent with the machine

    private func reconcile() {
        guard config.meetingsEnabled else {
            stop()
            // Disabling re-arms the prime: someone who turns the feature
            // back on is asking the question again and deserves the card
            // again, this boot included.
            primeShownThisBoot = false
            return
        }
        switch authorization {
        case _ where authorized:
            reportedDenied = false
            grantPoll?.invalidate(); grantPoll = nil
            prime.orderOut(nil)
            start()
        case .notDetermined:
            pollForGrant()
            guard !primeShownThisBoot else { return }
            primeShownThisBoot = true
            showPrime()
        default:
            stop()
            pollForGrant()
            if !reportedDenied {
                reportedDenied = true
                Log.error("meetings: enabled but calendar access is denied")
                flash?("Meetings need calendar access. Allow Lodestar under "
                    + "Privacy and Security, Calendars.")
            }
        }
    }

    /// The grant can arrive because we asked or because they went to
    /// System Settings themselves, and both endings must be the same:
    /// meetings wake up on their own the moment access lands.
    private func pollForGrant() {
        guard grantPoll == nil else { return }
        grantPoll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.config.meetingsEnabled else {
                self.grantPoll?.invalidate(); self.grantPoll = nil
                return
            }
            if self.authorized {
                self.grantPoll?.invalidate(); self.grantPoll = nil
                Log.info("meetings", ["calendar-access": "granted"])
                self.reconcile()
            }
        }
    }

    private func start() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            self.pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func stop() {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        tick?.invalidate(); tick = nil
        pendingRefresh?.cancel(); pendingRefresh = nil
        grantPoll?.invalidate(); grantPoll = nil
        occurrences = []
        current = nil
        panel.orderOut(nil)
        prime.orderOut(nil)
    }

    // MARK: - The calendar, read

    /// The window reaches back far enough to keep a long meeting that
    /// started hours ago, and forward a day. Declined and all-day events
    /// never become occurrences; neither does anything without a
    /// recognizable meeting link.
    private func refresh() {
        // Off the main thread, always: the event tap shares the main run
        // loop, and a calendar database is exactly the kind of neighbor
        // that answers slowly on the wrong morning. The EKEvent objects
        // are reduced to value types on the fetch queue and never cross it.
        guard !refreshing else { return }
        refreshing = true
        let store = store
        let now = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let predicate = store.predicateForEvents(
                withStart: now.addingTimeInterval(-12 * 3600),
                end: now.addingTimeInterval(24 * 3600), calendars: nil)
            let fetched: [Meetings.Occurrence] = store.events(matching: predicate)
                .compactMap { event in
                    guard !event.isAllDay else { return nil }
                    if let me = event.attendees?.first(where: { $0.isCurrentUser }),
                       me.participantStatus == .declined { return nil }
                    guard let link = Meetings.sniff(url: event.url?.absoluteString,
                                                    location: event.location,
                                                    notes: event.notes) else { return nil }
                    return Meetings.Occurrence(
                        eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
                        title: event.title ?? "meeting",
                        start: event.startDate, end: event.endDate,
                        link: link,
                        calendar: event.calendar?.title,
                        account: event.calendar?.source?.title)
                }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.occurrences = fetched
                // Never prune against an empty fetch: EventKit can answer
                // empty for a beat (a sync hiccup, an account briefly
                // offline), and a wiped spent set would resurrect a
                // dismissed chip when the events return. A truly empty
                // calendar offers nothing anyway; the stale keys wait for
                // the next real fetch to prune them.
                if !fetched.isEmpty {
                    self.saveSpent(Meetings.prune(spent: self.loadSpent(), keeping: fetched))
                    // The offered set answers "was this chip's observation
                    // recorded"; keys whose occurrences are gone are done
                    // answering.
                    self.offered.formIntersection(fetched.map(\.key))
                }
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        let candidate = Meetings.candidate(occurrences: occurrences, now: Date(),
                                           leadMinutes: config.meetingsLeadMinutes,
                                           spent: loadSpent())
        current = candidate
        guard let candidate, !suppressed() else {
            panel.orderOut(nil)
            return
        }
        if !offered.contains(candidate.occurrence.key) {
            offered.insert(candidate.occurrence.key)
            let resolved = resolve(candidate.occurrence)
            observations?.meetingChip(action: "offered",
                                      provider: candidate.occurrence.link.provider.rawValue,
                                      decider: resolved.deciderLabel)
        }
        render(candidate)
    }

    // MARK: - The profile, decided

    private struct Resolved {
        let profile: BrowserProfile?
        let profileLabel: String
        let deciderLabel: String
    }

    /// The calendar mapping first, because two meetings on the same host
    /// are told apart by nothing else. Unmapped inherits the web routing
    /// chain untouched. Native joins ignore all of this — Zoom is Zoom.
    private func resolve(_ occurrence: Meetings.Occurrence) -> Resolved {
        if let mapped = Meetings.mappedProfile(calendar: occurrence.calendar,
                                               account: occurrence.account,
                                               mappings: config.meetingsCalendars),
           let profile = config.browserProfiles[mapped.profile] {
            return Resolved(profile: profile, profileLabel: profile.display,
                            deciderLabel: "calendar")
        }
        if let resolved = resolveWeb?(occurrence.link.url) {
            return Resolved(profile: resolved.profile,
                            profileLabel: resolved.profile.display,
                            deciderLabel: resolved.label)
        }
        return Resolved(profile: nil, profileLabel: "browser", deciderLabel: "default")
    }

    // MARK: - The two gestures

    /// Lode lode while the chip is up. Joining spends the occurrence: a
    /// chip that keeps saying "join" through the meeting it opened is
    /// noise wearing a countdown.
    func join() -> Bool {
        guard chipVisible, let candidate = current else { return false }
        let occurrence = candidate.occurrence
        let resolved = resolve(occurrence)
        spend(occurrence, action: "joined",
              decider: resolved.deciderLabel,
              lead: Date().timeIntervalSince(occurrence.start))
        // Never the title and never the URL in the log. Where something
        // opened is what a bug report needs.
        if let native = Meetings.nativeJoin(for: occurrence.link),
           let appURL = native.bundleIDs.lazy.compactMap({
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
           }).first,
           let url = URL(string: native.url) {
            Log.info("meeting", ["join": occurrence.link.provider.rawValue, "via": "app"])
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        Log.info("meeting", ["join": occurrence.link.provider.rawValue,
                             "via": "browser", "decider": resolved.deciderLabel])
        if let profile = resolved.profile {
            openWeb?(occurrence.link.url, profile)
        } else if let url = URL(string: occurrence.link.url) {
            // No profiles registered at all: the plain system open.
            NSWorkspace.shared.open(url)
        }
        return true
    }

    /// Lode ⌫ while the chip is up: this instance, never the series.
    func dismiss() -> Bool {
        guard chipVisible, let candidate = current else { return false }
        spend(candidate.occurrence, action: "dismissed",
              decider: resolve(candidate.occurrence).deciderLabel, lead: nil)
        return true
    }

    private func spend(_ occurrence: Meetings.Occurrence, action: String,
                       decider: String, lead: Double?) {
        var spent = loadSpent()
        spent.insert(occurrence.key)
        saveSpent(Meetings.prune(spent: spent, keeping: occurrences))
        observations?.meetingChip(action: action,
                                  provider: occurrence.link.provider.rawValue,
                                  decider: decider, lead: lead)
        panel.orderOut(nil)
        current = nil
        // An overlapping meeting may be next in line this same minute.
        evaluate()
    }

    // MARK: - The chip, drawn

    private func render(_ candidate: Meetings.Candidate) {
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }
        let occurrence = candidate.occurrence
        let resolved = resolve(occurrence)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        var title = occurrence.title
        if title.count > 40 { title = String(title.prefix(39)) + "…" }
        stack.addArrangedSubview(label("⌖ meeting", size: 10.5, weight: .medium,
                                       color: .tertiaryLabelColor))
        stack.addArrangedSubview(label(title, size: 14, weight: .semibold,
                                       color: .labelColor))

        let phase: String
        switch candidate.phase {
        case .upcoming(let minutes): phase = "in \(minutes) min"
        case .now: phase = "now"
        case .inProgress(let minutes): phase = "\(minutes) min in"
        }
        let destination = Meetings.nativeJoin(for: occurrence.link) != nil
            ? occurrence.link.provider.rawValue
            : "\(resolved.profileLabel) · \(resolved.deciderLabel)"
        stack.addArrangedSubview(label("\(phase) · \(destination)", size: 12,
                                       weight: .regular, color: .secondaryLabelColor))
        stack.setCustomSpacing(9, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(Keycaps.line([
            .init(["lode", "lode"], "joins"),
            .init(["lode", "⌫"], "dismisses"),
        ]))

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.chipWidth,
                          height: stack.fittingSize.height + 13 + 12)
        let visible = ActivePolicy.presentationFrame
        let origin = NSPoint(x: visible.maxX - size.width - 20,
                             y: visible.maxY - size.height - 20)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        // Only on the way up: render is called again to retitle a chip that
        // is already standing, and that is not a fresh claim.
        if !wasVisible { onChipShown() }
    }

    // MARK: - The prime card

    private func showPrime() {
        for view in primeRoot.subviews where view is NSStackView { view.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("Meetings", size: 22, weight: .semibold,
                                       color: .labelColor))
        let body = NSTextField(wrappingLabelWithString:
            "Lodestar can offer your next meeting a few minutes before it "
            + "starts. Tap lode twice and you are in it, in the right app "
            + "or browser profile.\n\nmacOS asks you to allow calendar "
            + "access first. Nothing about your events leaves your Mac.")
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.isSelectable = false
        body.preferredMaxLayoutWidth = Self.primeWidth - 52
        body.widthAnchor.constraint(lessThanOrEqualToConstant: Self.primeWidth - 52).isActive = true
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(16, after: body)

        let allow = NSButton(title: "Allow Calendar Access", target: self,
                             action: #selector(allowButton))
        allow.bezelStyle = .rounded
        allow.controlSize = .large
        allow.keyEquivalent = "\r"
        stack.addArrangedSubview(allow)
        let notNow = NSButton(title: "not now", target: self, action: #selector(notNowButton))
        notNow.isBordered = false
        notNow.font = .systemFont(ofSize: 11.5)
        notNow.contentTintColor = .tertiaryLabelColor
        stack.addArrangedSubview(notNow)

        primeRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: primeRoot.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: primeRoot.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: primeRoot.trailingAnchor, constant: -26),
        ])
        primeRoot.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.primeWidth,
                          height: stack.fittingSize.height + 28 + 24)
        let visible = ActivePolicy.presentationFrame
        prime.setFrame(NSRect(x: visible.midX - size.width / 2,
                              y: visible.midY - size.height / 2 + 40,
                              width: size.width, height: size.height), display: true)
        prime.makeKeyAndOrderFront(nil)
    }

    @objc private func allowButton() { allowPressed() }
    @objc private func notNowButton() { notNowPressed() }

    private func allowPressed() {
        prime.orderOut(nil)
        let handle: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                Log.info("meetings", ["calendar-access": granted ? "granted" : "denied"])
                self.reconcile()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in handle(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in handle(granted) }
        }
    }

    /// "Not now" unwinds the one config line, or the prime card would
    /// greet every boot with a question already answered.
    private func notNowPressed() {
        prime.orderOut(nil)
        _ = setEnabled?(false)
    }

    // MARK: - Pieces

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: - Staging

    #if DEBUG
    /// `lodestar __strip-preview 60` stages the chip, 61 the prime card.
    static func preview(_ index: Int) -> MeetingController {
        let controller = MeetingController()
        var (config, _) = Config.load()
        config.meetingsEnabled = true
        controller.config = config
        DispatchQueue.main.async {
            if index == 0 {
                let start = Date().addingTimeInterval(4 * 60)
                let occurrence = Meetings.Occurrence(
                    eventID: "preview", title: "Product sync",
                    start: start, end: start.addingTimeInterval(30 * 60),
                    link: Meetings.Link(provider: .meet,
                                        url: "https://meet.google.com/abc-defg-hij"),
                    calendar: "Work", account: "Google")
                controller.occurrences = [occurrence]
                controller.evaluate()
                // The chip's own titled, deferred, never-key panel refuses
                // to reach the window server in this headless process, so
                // the photograph borrows the searcher's panel shell and
                // wears the chip's real content view — every pixel inside
                // the glass is the production render.
                let frame = controller.panel.frame
                let content = controller.panel.contentView
                controller.panel.orderOut(nil)
                let host = KeyablePanel(
                    contentRect: frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
                host.level = .floating
                host.isOpaque = false
                host.backgroundColor = .clear
                host.hasShadow = true
                host.isReleasedWhenClosed = false
                host.contentView = content
                host.setFrame(frame, display: true)
                host.makeKeyAndOrderFront(nil)
                host.orderFrontRegardless()
                previewHost = host
            } else {
                controller.showPrime()
            }
        }
        return controller
    }

    private static var previewHost: NSPanel?
    #endif
}
