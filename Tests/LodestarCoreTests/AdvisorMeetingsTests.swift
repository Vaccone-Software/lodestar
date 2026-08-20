import XCTest
@testable import LodestarCore

final class AdvisorMeetingsTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func web(host: String, daysAgo: Double) -> ObservationEvent {
        var event = ObservationEvent(t: base.addingTimeInterval(-daysAgo * 86_400),
                                     kind: .web)
        event.host = host
        event.profile = "brave:Work"
        event.source = "click"
        return event
    }

    private func focus(app: String, daysAgo: Double, minute: Double = 0) -> ObservationEvent {
        var event = ObservationEvent(
            t: base.addingTimeInterval(-daysAgo * 86_400 + minute * 60), kind: .focus)
        event.app = app
        return event
    }

    private func context(events: [ObservationEvent],
                         meetingsEnabled: Bool = false) -> Advisor.Context {
        Advisor.Context(observations: Observations(), events: events,
                        leaves: [], meetingsEnabled: meetingsEnabled, now: base)
    }

    /// A steady meeting habit: several joins a week across four weeks.
    private var steadyHabit: [ObservationEvent] {
        var events: [ObservationEvent] = []
        for day in stride(from: 1.0, through: 27, by: 2) {
            events.append(web(host: "meet.google.com", daysAgo: day))
        }
        return events
    }

    func testSteadyMeetingHabitProducesTheOffer() {
        let candidates = Advisor.meetingsCandidates(context(events: steadyHabit))
        XCTAssertEqual(candidates.count, 1)
        let rec = candidates[0].0
        XCTAssertEqual(rec.kind, .meetings)
        XCTAssertEqual(rec.edit, .enableMeetings)
        XCTAssertGreaterThanOrEqual(rec.probability, 0.9)
        XCTAssertTrue(rec.evidence.contains { $0.contains("prior") },
                      "a priced claim the user cannot audit is not this voice")
    }

    func testEnabledRetiresTheOfferForever() {
        let candidates = Advisor.meetingsCandidates(
            context(events: steadyHabit, meetingsEnabled: true))
        XCTAssertTrue(candidates.isEmpty)
    }

    func testZoomAppFocusCountsAsMeetingActivity() {
        var events: [ObservationEvent] = []
        for day in stride(from: 1.0, through: 27, by: 2) {
            events.append(focus(app: "zoom.us", daysAgo: day))
        }
        let candidates = Advisor.meetingsCandidates(context(events: events))
        XCTAssertEqual(candidates.count, 1)
    }

    func testOneJoinThrowingTwoSignalsCountsOnce() {
        // A clicked Zoom link routes through us and lands on the Zoom app:
        // a web event and a focus event within a minute, one meeting.
        var doubled: [ObservationEvent] = []
        for day in stride(from: 1.0, through: 27, by: 2) {
            doubled.append(web(host: "acme.zoom.us", daysAgo: day))
            doubled.append(focus(app: "zoom.us", daysAgo: day, minute: 1))
        }
        var single: [ObservationEvent] = []
        for day in stride(from: 1.0, through: 27, by: 2) {
            single.append(web(host: "acme.zoom.us", daysAgo: day))
        }
        let fromDoubled = Advisor.meetingsCandidates(context(events: doubled))
        let fromSingle = Advisor.meetingsCandidates(context(events: single))
        XCTAssertEqual(fromDoubled.first?.0.detail, fromSingle.first?.0.detail,
                       "sessionization must collapse the echo")
    }

    func testRefocusingMidCallIsNotAnotherJoin() {
        var events: [ObservationEvent] = []
        for day in stride(from: 1.0, through: 27, by: 2) {
            events.append(focus(app: "zoom.us", daysAgo: day))
            events.append(focus(app: "zoom.us", daysAgo: day, minute: 10))
            events.append(focus(app: "zoom.us", daysAgo: day, minute: 25))
        }
        let candidates = Advisor.meetingsCandidates(context(events: events))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates.first?.0.evidence
                        .contains { $0.contains("14 manual joins") } ?? false,
                      "three focus arrivals inside half an hour are one meeting")
    }

    func testNoMeetingActivityStaysSilent() {
        let events = [web(host: "github.com", daysAgo: 2),
                      focus(app: "brave browser", daysAgo: 1)]
        XCTAssertTrue(Advisor.meetingsCandidates(context(events: events)).isEmpty)
    }

    func testOneThinWeekSelfSuppresses() {
        let events = [web(host: "meet.google.com", daysAgo: 1)]
        XCTAssertTrue(Advisor.meetingsCandidates(context(events: events)).isEmpty,
                      "a single week of data is not a habit")
    }

    func testMeetingCueMatchesHostsAndApps() {
        let rec = Recommendation(kind: .meetings, target: "meetings", detail: "",
                                 secondsPerWeek: 60, probability: 0.95, evidence: [],
                                 edit: .enableMeetings)
        XCTAssertEqual(Coach.cue(for: rec), .meeting)
        XCTAssertTrue(Meetings.isMeetingHost("acme.zoom.us"))
        XCTAssertTrue(Meetings.isMeetingHost("meet.google.com"))
        XCTAssertFalse(Meetings.isMeetingHost("notzoom.us.example.com"))
        XCTAssertTrue(Meetings.meetingApps.contains("zoom.us"))
    }

    func testChipCopyForTheMeetingsOffer() {
        let rec = Recommendation(kind: .meetings, target: "meetings",
                                 detail: "about 4 meetings a week joined by hand",
                                 secondsPerWeek: 80, probability: 0.95, evidence: [],
                                 edit: .enableMeetings)
        let chip = Coach.chip(for: rec, observations: Observations())
        XCTAssertEqual(chip.headline, "meetings at the door")
        XCTAssertTrue(chip.evidence.hasPrefix("about 4 meetings a week joined by hand"))
        XCTAssertTrue(chip.footer.contains("tap lode twice"))
    }
}
