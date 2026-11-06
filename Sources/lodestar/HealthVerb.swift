import Foundation
import LodestarCore

/// `lodestar health`: the health record, read. Two doors: `export` decrypts
/// it to files; every other word reads it as JSON lines on standard output
/// and writes nothing (`HealthQuery`). The same signed binary asks the same
/// keychain, and never makes a key.
func runHealthVerb(_ arguments: [String]) -> Never {
    Log.stdoutEnabled = false
    let rest = Array(arguments.dropFirst())
    switch rest.first {
    case "export": runHealthExport(rest)
    case "schema":
        print(healthGuide)
        exit(0)
    case let word? where HealthQuery.Grain(rawValue: word) != nil:
        runHealthQuery(HealthQuery.Grain(rawValue: word)!, Array(rest.dropFirst()))
    default:
        print(healthUsage)
        exit(64)
    }
}

private let healthUsage = """
usage: lodestar health <grain> [--since YYYY-MM-DD] [--until YYYY-MM-DD]
       lodestar health press --include-presses [--since …] [--until …]
       lodestar health schema
       lodestar health export <dir> [--logbook]

grains: summary day week month · pulse window bout blind voice click era · press
  JSON lines on standard output, nothing written to disk. The first line says
  what was read; every row says how it was measured. `schema` explains each
  field. `press` is the raw press record and needs --include-presses.
"""

private func runHealthQuery(_ grain: HealthQuery.Grain, _ flags: [String]) -> Never {
    var days = HealthQuery.Days()
    var includePresses = false
    var index = 0
    while index < flags.count {
        let flag = flags[index]
        switch flag {
        case "--since", "--until":
            guard index + 1 < flags.count, HealthQuery.Days.isDay(flags[index + 1], calendar: .current) else {
                print("✕ \(flag) takes a day: YYYY-MM-DD")
                exit(64)
            }
            if flag == "--since" { days.since = flags[index + 1] } else { days.until = flags[index + 1] }
            index += 2
        case "--include-presses":
            includePresses = true
            index += 1
        default:
            print("✕ unknown flag \(flag)\n\n" + healthUsage)
            exit(64)
        }
    }
    if grain == .press, !includePresses {
        print("""
        ✕ the press record is held back unless asked for by flag.
          Each row is one keystroke: its hand, finger, class and timing, never the key.
          That still sorts letters into groups, so with the gaps between words it is a
          partial transcript of what was typed. Anything it is piped to can read that.
          Run again with --include-presses to read it.
        """)
        exit(64)
    }
    guard let vault = try? Vault.system() else {
        print("✕ the keychain is not available to this process")
        exit(69)
    }
    let calendar = Calendar.current
    let ring = vault.ring(.health)
    let record = HealthRecord.read(in: Paths.data, ring: ring)
    if case .paused(let why) = ring.availability {
        print("✕ the health record is sealed and its key is unavailable (\(why.words)); nothing was read")
        exit(69)
    }
    let timeline = HealthMeasurement.Timeline(events: record.events)
    var problems = record.problems
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func emit(_ row: some Encodable) {
        guard let data = try? encoder.encode(row) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    switch grain {
    case .press:
        var rows: [HealthQuery.Press] = []
        for day in HealthRecord.pressDays(in: Paths.data) where days.contains(day: day) {
            let read = HealthRecord.presses(day: day, in: Paths.data, ring: ring)
            if let problem = read.problem { problems.append(problem) }
            rows += HealthQuery.presses(read.presses, day: day, timeline: timeline)
        }
        emit(HealthQuery.header(grain: grain, days: days, timeline: timeline, problems: problems, calendar: calendar))
        rows.forEach(emit)
    case .bout:
        emit(HealthQuery.header(grain: grain, days: days, timeline: timeline, problems: problems, calendar: calendar))
        HealthQuery.bouts(events: record.events, timeline: timeline, days: days, calendar: calendar).forEach(emit)
    case .summary, .day, .week, .month:
        emit(HealthQuery.header(grain: grain, days: days, timeline: timeline, problems: problems, calendar: calendar))
        HealthQuery.periods(grain, events: record.events, timeline: timeline, days: days, calendar: calendar).forEach(emit)
    case .pulse, .window, .blind, .voice, .click, .era:
        emit(HealthQuery.header(grain: grain, days: days, timeline: timeline, problems: problems, calendar: calendar))
        HealthQuery.events(grain, events: record.events, timeline: timeline, days: days, calendar: calendar).forEach(emit)
    }
    exit(problems.isEmpty ? 0 : 1)
}

/// `lodestar health export <dir> [--logbook]`: the sealed record, decrypted
/// to the plaintext formats it was kept in (`RecordExport`), into a new or
/// empty folder, files 0600, and what was written said plainly. Nothing is
/// written into the data directory, and a record that does not open is
/// reported, not exported as empty. Exit 0 when everything was written, 1
/// when something could not be read, 64 for usage, 69 when the keychain is
/// not available.
private func runHealthExport(_ rest: [String]) -> Never {
    guard rest.count >= 2, !rest[1].hasPrefix("--") else {
        print("usage: lodestar health export <dir> [--logbook]")
        print("  decrypts the health record (or, with --logbook, the logbook) to plaintext files in <dir>")
        exit(64)
    }
    guard let vault = try? Vault.system() else {
        print("✕ the keychain is not available to this process")
        exit(69)
    }
    let destination = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath)
    let logbook = rest.contains("--logbook")
    do {
        let report = try RecordExport.export(logbook: logbook, from: Paths.data, to: destination, vault: vault)
        for file in report.written { print("wrote \(file.path) (\(file.bytes) bytes)") }
        let total = report.written.reduce(0) { $0 + $1.bytes }
        print("\(report.written.count) files, \(total) bytes, in \(destination.path) — plaintext: keep it where you keep the record's trust, and delete it when you are done")
        for problem in report.problems { print("✕ \(problem)") }
        exit(report.ok ? 0 : 1)
    } catch {
        print("✕ \(error)")
        exit(1)
    }
}

/// What `lodestar health schema` prints: every grain and field, plainly
/// enough that a person, or a model they hand the rows to, can read them
/// without the source.
private let healthGuide = """
lodestar health · schema \(HealthQuery.schema)

What this is
  The health record Lodestar keeps on this Mac, read as JSON lines. Nothing is
  written to disk; whatever you pipe the output to can read it. Times are Unix
  seconds. A day is a health day: it starts at 04:00 local time, so an evening
  that runs past midnight stays one day. Durations end in their unit (Ms,
  Seconds, Minutes, Hours); a share or rate is a fraction from 0 to 1.

The first line (row "header")
  problems        files that did not open; if any, the rows are not the whole record
  measurements    each change in anything a period reads, oldest first, with the
                  build that began it (the era grain lists every build)
  reportIntervals how often each keyboard says it reports, in microseconds, or
                  "unknown": holds from it fall on this grid. A Bluetooth link
                  can add a coarser grid of its own (7.5 to 15 ms) whatever the
                  keyboard states, so read a hold's resolution off its spacing too

measurement (on every event, bout and press row)
  How that moment of the record was measured.
  build           the Lodestar version that wrote it; null before 0.35.0
  basis           "era": read from the record. "inferred": before 0.35.0, read
                  from which columns the pulses carry
  holdClock       none (no holds, before 0.31.2) · callback (the app's own clock,
                  0.31.2 to 0.33; the switch at 0.34.0 left no step in the mean)
                  · eventStamp (the key event's own timestamp, 0.34.0 on)
  bouts           pulses carry a bout position and the pauses (0.31.2 on)
  windows         90 s windows and the raw press record exist (0.34.0 on)
  keyboardList    what a pulse's keyboards mean: launchSnapshot (attached when
                  Lodestar launched, 0.34.0 to 0.39.1: unreliable) · live (0.39.2 on)
  pressKeyboard   how a press's keyboard was decided: lid (0.34.0 to 0.39.1: with
                  the lid open, Bluetooth presses were charged to the built-in;
                  use keyboardType instead) · keyboardType (0.39.2 on) · exact.
                  Each launch writes it twice, a minute apart, as Input
                  Monitoring is confirmed
  blindSpans      times the instrument could not see were recorded (0.46.0 on).
                  Before that, blind time is unknown, not zero
  reportIntervals keyboards' report intervals were written down (0.46.0 on)
  voice           spoken drafts were measured (0.53.0 on)
  pointerSchema   the raw pointer record's format

measurement (on period rows)
  basis           "inferred" if any part of the period was
  holdClock, keyboardList   as above. A change in either changes what a number
                  means, so a period is cut there and never summed across it
  recorded        for bouts, windows, blindSpans and voice: the share of the
                  period's time, 0 to 1, under builds that recorded it. Builds
                  alternate around a release, so this can be below 1 on a day
                  something was recorded. Its section covers only that share,
                  and is null when the share is 0

Periods: summary, day, week (Monday to Sunday), month
  One row per period that holds any record; summary is the whole span. A
  period that crosses a change in what its numbers mean is cut there: each
  part is its own row with split true. Sections are null when not measured.
  firstDay lastDay start end   the part's bounds
  builds          every build that wrote in it
  activeDays      days with any typing or pointing
  input           keys, backspaces, correctionRate, backspaceRunKeys (single, two
                  to four, five or more), activeMinutes, longestStretchMinutes (a
                  gap of 20 minutes ends a stretch), interKeyMeanMs/SDMs (gaps
                  under 2 s), interKeyMedianMs, pauses (gaps over 2 s inside a
                  bout), pauseMeanSeconds, pauseShare, fixMeanMs (last key to the
                  first backspace of a run), minutesByHour (24, from midnight)
  hold            press to release, autorepeat excluded: n, meanMs, sdMs, cv,
                  p10Ms medianMs p90Ms (read off a histogram with four bins to an
                  octave, so about ±9%), coverage (holds per key counted)
  windows         90 s windows with 30 or more typing presses are valid. Medians
                  across valid windows: holdSDMedianMs, holdMedianMs,
                  fluctSDMedian (SD of log(hold n+1 / hold n), Lan & Yeo 2019),
                  vIQRMedian vOutMedian (Giancardo 2016), overlapShare (pairs
                  that rolled over), asymmetryMedianMs (left minus right hand);
                  holdSDSpreadMs is the SD of the windows' SDs
  bouts           a bout ends after 10 minutes without input: count, meanMinutes,
                  longestMinutes, and drift per hour into a bout for corrections,
                  pauses and hold, fitted within bouts, with its standard error;
                  distinguishable means it clears twice its error
  rhythm          on two or more active days: interdailyStability (0 to 1, alike
                  days), intradailyVariability (0 to 2, broken up),
                  relativeAmplitude, m10/l5 (most and least active hours),
                  onset/offset/midpoint hours (may pass 24), socialJetlagHours
                  (weekday vs weekend midpoint, of activity, not sleep)
  pointer         clicks, clicksPosted (not the hand's), scrolls and their
                  seconds, scrollPreciseShare (trackpad), scrollMomentumShare,
                  fromKeysShare, and a reach measured: homing, travel, settle,
                  press and return seconds, pathPoints, straightness, drags
  voice           medians across spoken drafts: f0Hz, jitter, shimmer, hnrDb,
                  wordsPerSecond. From live speech through whatever mic was in
                  use: not comparable with clinical sustained-vowel norms
  blind           seconds unseen by kind (asleep, secureInput, notRunning,
                  tapOff, untrusted, healthOff, keyUnavailable), spans cut to the
                  period, over the share measurement.recorded.blindSpans says
  quality         tapLateMs, tapResets, keyboards (id: report interval)

Events: pulse, window, blind, voice, click, era
  One row per stored event, as the record keeps it ("event"), with its day and
  measurement. pulse: a quarter hour of input (keys, holds, rhythm histograms,
  bout position). window: one 90 s window's order statistics by hand and
  direction, with its app and keyboards. blind: a span the instrument could
  not see. voice: one spoken draft's measures. click: a quarter hour of clicks
  in one app, with the reach moments. era: the instrument changed.

bout
  One row per bout: day, start, minutes, pulses, keys, correctionRate,
  holdMeanMs; joined means the record began inside it or a change in
  measurement cut it.

press (needs --include-presses)
  One row per keystroke, never the key itself: down, holdMs (null: no release
  seen), hand, finger, kind, typing (a letter, digit, space or punctuation, not
  chorded, a gesture or repeated), shift chord gesture lens repeated armed,
  modifiers held, struck, keyboardType (91 built-in, 40 external), keyboard (the
  roster id it was charged to), lid. Hand, finger and kind sort letters into
  groups and the spaces show where words end: a partial transcript of what was
  typed. Read it only where you would keep the text itself.
"""
