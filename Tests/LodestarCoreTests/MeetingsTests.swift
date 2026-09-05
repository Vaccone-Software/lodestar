import XCTest
@testable import LodestarCore

final class MeetingsTests: XCTestCase {
    // MARK: - The sniffer

    func testSniffsZoomFromLocation() {
        let link = Meetings.sniff(url: nil,
                                  location: "Join: https://acme.zoom.us/j/91234567890?pwd=abC123",
                                  notes: nil)
        XCTAssertEqual(link, Meetings.Link(provider: .zoom,
                                           url: "https://acme.zoom.us/j/91234567890?pwd=abC123"))
    }

    func testSniffsMeetFromNotes() {
        // Google Calendar's Meet link never reaches EventKit's location.
        let notes = "Agenda:\n1. Roadmap\n\nJoin: https://meet.google.com/abc-defg-hij?authuser=1\n"
        let link = Meetings.sniff(url: nil, location: "Conference Room 4", notes: notes)
        XCTAssertEqual(link?.provider, .meet)
        XCTAssertEqual(link?.url, "https://meet.google.com/abc-defg-hij?authuser=1")
    }

    func testSniffsTeamsAndWebexAndFacetime() {
        XCTAssertEqual(Meetings.sniff(
            url: nil, location: nil,
            notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y")?.provider,
            .teams)
        XCTAssertEqual(Meetings.sniff(
            url: "https://acme.webex.com/meet/rvaccone", location: nil, notes: nil)?.provider,
            .webex)
        XCTAssertEqual(Meetings.sniff(
            url: nil, location: "https://facetime.apple.com/join#v=1&p=x", notes: nil)?.provider,
            .facetime)
    }

    func testFieldOrderIsURLThenLocationThenNotes() {
        let link = Meetings.sniff(url: "https://meet.google.com/aaa-bbbb-ccc",
                                  location: "https://acme.zoom.us/j/1",
                                  notes: "https://acme.webex.com/meet/x")
        XCTAssertEqual(link?.provider, .meet, "the URL property is the most trusted field")
    }

    func testNonMeetingLinksAreNotMeetings() {
        XCTAssertNil(Meetings.sniff(url: "https://zoom.us/pricing", location: nil, notes: nil))
        XCTAssertNil(Meetings.sniff(url: nil, location: "Conference Room 4",
                                    notes: "See https://github.com/acme/repo"))
        XCTAssertNil(Meetings.sniff(url: nil, location: nil, notes: nil))
    }

    // MARK: - Native hand-off

    func testZoomTransformsToTheAppWithPassword() {
        let link = Meetings.Link(provider: .zoom,
                                 url: "https://acme.zoom.us/j/91234567890?pwd=abC123")
        let native = Meetings.nativeJoin(for: link)
        XCTAssertEqual(native, Meetings.NativeJoin(
            url: "zoommtg://acme.zoom.us/join?confno=91234567890&pwd=abC123",
            bundleIDs: ["us.zoom.xos"]))
    }

    func testZoomPersonalRoomDoesNotTransform() {
        // /my/ links are vanity URLs whose meeting id is unknown; they
        // must fall through to the browser rather than break in the app.
        let link = Meetings.Link(provider: .zoom, url: "https://zoom.us/my/rvaccone")
        XCTAssertNil(Meetings.nativeJoin(for: link))
    }

    func testTeamsWrapsItsOwnLink() {
        let link = Meetings.Link(provider: .teams,
                                 url: "https://teams.microsoft.com/l/meetup-join/19%3ax/0")
        XCTAssertEqual(Meetings.nativeJoin(for: link)?.url,
                       "msteams://teams.microsoft.com/l/meetup-join/19%3ax/0")
    }

    func testEarliestLinkWinsWhenNotesCarryTwo() {
        // "Moved off Zoom" notes keep the old link; the one the organizer
        // put first is the one they mean, whatever the provider order is.
        let notes = "Join: https://meet.google.com/abc-defg-hij\n"
            + "(old link: https://acme.zoom.us/j/111)"
        XCTAssertEqual(Meetings.sniff(url: nil, location: nil, notes: notes)?.provider, .meet)
        let reversed = "https://acme.zoom.us/j/111 moved to https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(Meetings.sniff(url: nil, location: nil, notes: reversed)?.provider, .zoom)
    }

    func testMeetLookupAndZoomGovAreMeetings() {
        XCTAssertEqual(Meetings.sniff(url: "https://meet.google.com/lookup/team-standup",
                                      location: nil, notes: nil)?.provider, .meet)
        let gov = Meetings.sniff(url: "https://agency.zoomgov.com/j/1600000000",
                                 location: nil, notes: nil)
        XCTAssertEqual(gov?.provider, .zoom)
        XCTAssertNil(Meetings.nativeJoin(for: gov!),
                     "the government client is not the consumer client")
        XCTAssertTrue(Meetings.isMeetingHost("agency.zoomgov.com"))
    }

    func testEncodedPasswordSurvivesTheTransform() {
        let link = Meetings.Link(provider: .zoom,
                                 url: "https://zoom.us/j/123?pwd=a%2Bb%3D")
        XCTAssertEqual(Meetings.nativeJoin(for: link)?.url,
                       "zoommtg://zoom.us/join?confno=123&pwd=a%2Bb%3D",
                       "queryItems decodes and re-embedding corrupts encoded bytes")
    }

    func testTeamsOffersBothClients() {
        let link = Meetings.Link(provider: .teams,
                                 url: "https://teams.microsoft.com/l/meetup-join/19%3ax/0")
        XCTAssertEqual(Meetings.nativeJoin(for: link)?.bundleIDs,
                       ["com.microsoft.teams2", "com.microsoft.teams"])
    }

    func testBrowserProvidersHaveNoNativeJoin() {
        for provider in [Meetings.Provider.meet, .webex, .facetime] {
            let link = Meetings.Link(provider: provider, url: "https://example.com/x")
            XCTAssertNil(Meetings.nativeJoin(for: link))
        }
    }

    // MARK: - Profile resolution

    func testCalendarNameOutranksAccountName() {
        let resolved = Meetings.mappedProfile(calendar: "Standups", account: "Work",
                                              mappings: ["standups": "personal",
                                                         "work": "google-work"])
        XCTAssertEqual(resolved?.profile, "personal")
        XCTAssertEqual(resolved?.decider, .calendar("Standups"))
    }

    func testAccountAnswersWhenCalendarIsUnmapped() {
        let resolved = Meetings.mappedProfile(calendar: "Team offsites", account: "Work",
                                              mappings: ["Work": "google-work"])
        XCTAssertEqual(resolved?.profile, "google-work")
    }

    func testUnmappedMeansInherit() {
        XCTAssertNil(Meetings.mappedProfile(calendar: "Home", account: "iCloud",
                                            mappings: ["Work": "google-work"]),
                     "nil defers to the web routing chain, never guesses")
    }

    func testMappingMatchesCaseInsensitively() {
        let resolved = Meetings.mappedProfile(calendar: "WORK", account: nil,
                                              mappings: ["work": "google-work"])
        XCTAssertEqual(resolved?.profile, "google-work")
    }

    // MARK: - The chip

    private func occurrence(_ id: String, startsIn minutes: Double, lasts: Double = 30,
                            title: String = "Standup") -> Meetings.Occurrence {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000 + minutes * 60)
        return Meetings.Occurrence(
            eventID: id, title: title, start: start,
            end: start.addingTimeInterval(lasts * 60),
            link: Meetings.Link(provider: .meet, url: "https://meet.google.com/aaa-bbbb-ccc"),
            calendar: "Work", account: "Google")
    }

    private var now: Date { Date(timeIntervalSinceReferenceDate: 1_000_000) }

    func testChipAppearsInsideTheLeadWindow() {
        let soon = occurrence("a", startsIn: 4)
        let later = occurrence("b", startsIn: 40)
        let candidate = Meetings.candidate(occurrences: [later, soon], now: now,
                                           leadMinutes: 5, spent: [])
        XCTAssertEqual(candidate?.occurrence, soon)
        XCTAssertEqual(candidate?.phase, .upcoming(minutes: 4))
        XCTAssertNil(Meetings.candidate(occurrences: [later], now: now,
                                        leadMinutes: 5, spent: []),
                     "forty minutes out is not a chip")
    }

    func testChipLivesTheWholeMeetingAndCountsIn() {
        let running = occurrence("a", startsIn: -10, lasts: 30)
        let candidate = Meetings.candidate(occurrences: [running], now: now,
                                           leadMinutes: 5, spent: [])
        XCTAssertEqual(candidate?.phase, .inProgress(minutes: 10))
        let over = occurrence("b", startsIn: -40, lasts: 30)
        XCTAssertNil(Meetings.candidate(occurrences: [over], now: now,
                                        leadMinutes: 5, spent: []),
                     "an ended meeting is nobody's chip")
    }

    func testOverlapShowsTheSoonestAndThenTheNext() {
        let first = occurrence("a", startsIn: 2)
        let second = occurrence("b", startsIn: 4)
        XCTAssertEqual(Meetings.candidate(occurrences: [second, first], now: now,
                                          leadMinutes: 5, spent: [])?.occurrence, first)
        XCTAssertEqual(Meetings.candidate(occurrences: [second, first], now: now,
                                          leadMinutes: 5, spent: [first.key])?.occurrence,
                       second,
                       "a spent chip yields to the next meeting, never resurrects")
    }

    func testSpentIsPerOccurrenceNotPerSeries() {
        let today = occurrence("series-1", startsIn: 0)
        let tomorrow = Meetings.Occurrence(
            eventID: "series-1", title: "Standup",
            start: today.start.addingTimeInterval(86_400),
            end: today.end.addingTimeInterval(86_400),
            link: today.link, calendar: "Work", account: "Google")
        XCTAssertNotEqual(today.key, tomorrow.key,
                          "recurrence shares an event id; the key must not")
    }

    func testAllSpentMeansNoChip() {
        let soon = occurrence("a", startsIn: 3)
        XCTAssertNil(Meetings.candidate(occurrences: [soon], now: now,
                                        leadMinutes: 5, spent: [soon.key]))
    }

    func testZeroLeadShowsAtTheDoorOnly() {
        let soon = occurrence("a", startsIn: 3)
        XCTAssertNil(Meetings.candidate(occurrences: [soon], now: now,
                                        leadMinutes: 0, spent: []),
                     "lead zero means the chip waits for the start")
        let started = occurrence("b", startsIn: -1)
        XCTAssertNotNil(Meetings.candidate(occurrences: [started], now: now,
                                           leadMinutes: 0, spent: []))
    }

    func testPruneDropsThePast() {
        let live = occurrence("a", startsIn: 3)
        let pruned = Meetings.prune(spent: [live.key, "gone@123"], keeping: [live])
        XCTAssertEqual(pruned, [live.key])
    }

    // MARK: - The countdown

    /// Whole minutes count down the way a hand counts a wait: three at
    /// 3:59. Rounding said two at 1:31, which read as a clock running fast.
    func testMinutesAreCountedDownNotRounded() {
        XCTAssertEqual(Meetings.phase(untilStart: 4 * 60), .upcoming(minutes: 4))
        XCTAssertEqual(Meetings.phase(untilStart: 3 * 60 + 59), .upcoming(minutes: 3))
        XCTAssertEqual(Meetings.phase(untilStart: 91), .upcoming(minutes: 1))
        XCTAssertEqual(Meetings.phase(untilStart: 61), .upcoming(minutes: 1))
    }

    func testUnderAMinuteTheSecondsCountDown() {
        XCTAssertEqual(Meetings.phase(untilStart: 60), .soon(seconds: 60))
        XCTAssertEqual(Meetings.phase(untilStart: 45.2), .soon(seconds: 46), "rounded up, so it never says 0")
        XCTAssertEqual(Meetings.phase(untilStart: 0.4), .soon(seconds: 1))
    }

    func testAtTheDoorItSaysNowAndThenCountsIn() {
        XCTAssertEqual(Meetings.phase(untilStart: 0), .now)
        XCTAssertEqual(Meetings.phase(untilStart: -89), .now)
        XCTAssertEqual(Meetings.phase(untilStart: -90), .inProgress(minutes: 1))
        XCTAssertEqual(Meetings.phase(untilStart: -10 * 60 - 30), .inProgress(minutes: 10))
    }

    func testTheCandidateCarriesTheSamePhaseRule() {
        let soon = occurrence("a", startsIn: 0.5)
        let candidate = Meetings.candidate(occurrences: [soon], now: now, leadMinutes: 5, spent: [])
        XCTAssertEqual(candidate?.phase, .soon(seconds: 30))
    }
}
