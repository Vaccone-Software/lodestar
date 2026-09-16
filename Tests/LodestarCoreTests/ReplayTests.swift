import XCTest
@testable import LodestarCore

/// The window code replayed over a published dataset, so its numbers can
/// be checked against numbers somebody else already printed.
///
/// neuroQWERTY MIT-CSXPD (Giancardo et al., Sci Rep 2016; PhysioNet):
/// 85 subjects, 42 with early Parkinson's, each typing a folk tale for
/// about fourteen minutes. The ground-truth file carries the paper's own
/// nQi per subject, so the AUC arithmetic here is checked against the
/// paper's 0.81 before anything of ours is measured with it. Lan & Yeo
/// (PLoS One 2019) then showed that the standard deviation of successive
/// log-hold ratios discriminates as well as nQi — 0.741 on their subset —
/// and that index is exactly `WindowStats.fluct.sd`, so the replay asks
/// whether the window code reproduces it.
///
/// Skipped unless `LODESTAR_DATASETS` names a directory holding the
/// dataset (`tools/health/fetch-datasets.sh` puts it there).
final class ReplayTests: XCTestCase {
    private struct Subject {
        let id: String
        let pd: Bool
        let nqi: Double?
        let presses: [[KeyPress]]
    }

    private var root: URL?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["LODESTAR_DATASETS"] else {
            throw XCTSkip("LODESTAR_DATASETS is unset; run tools/health/fetch-datasets.sh")
        }
        let dir = URL(fileURLWithPath: path).appendingPathComponent("neuroqwerty-mit-csxpd-dataset-1.0.0")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("neuroQWERTY dataset not found under \(path)")
        }
        root = dir
    }

    // MARK: - The dataset

    private func subjects() throws -> [Subject] {
        var out: [Subject] = []
        for study in ["MIT-CS1PD", "MIT-CS2PD"] {
            let base = root!.appendingPathComponent(study)
            let gt = try String(contentsOf: base.appendingPathComponent("GT_DataPD_\(study).csv"), encoding: .utf8)
            var lines = gt.split(whereSeparator: \.isNewline).map(String.init)
            guard !lines.isEmpty else { continue }
            let header = lines.removeFirst().split(separator: ",").map(String.init)
            let column = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
            for line in lines {
                let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard cells.count == header.count else { continue }
                let files = ["file_1", "file_2"].compactMap { column[$0] }.map { cells[$0] }.filter { !$0.isEmpty }
                let data = base.appendingPathComponent("data_\(study)")
                let presses = files.map { Self.load(data.appendingPathComponent($0)) }.filter { !$0.isEmpty }
                guard !presses.isEmpty else { continue }
                out.append(Subject(id: "\(study)/\(cells[column["pID"]!])",
                                   pd: cells[column["gt"]!] == "True",
                                   nqi: column["nqScore"].flatMap { Double(cells[$0]) },
                                   presses: presses))
            }
        }
        return out
    }

    /// One typing file: `"key",hold,release,press` per row, cleaned the
    /// way the dataset's own loader cleans it (nothing at or below zero,
    /// no hold of five seconds or more, presses in order).
    private static func load(_ url: URL) -> [KeyPress] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [KeyPress] = []
        var lastPress = -Double.infinity
        for line in text.split(whereSeparator: \.isNewline) {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == 4, let hold = Double(cells[1]), let release = Double(cells[2]),
                  let press = Double(cells[3]) else { continue }
            guard press > 0, release > 0, hold >= 0, hold < 5, press >= lastPress else { continue }
            lastPress = press
            let key = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let (hand, kind) = classify(key)
            out.append(KeyPress(down: Date(timeIntervalSince1970: 1_600_000_000 + press), hold: hold,
                                hand: hand, kind: kind, chord: false, gesture: false, repeated: false))
        }
        return out
    }

    private static let punctuationNames: Set<String> = [
        "period", "comma", "colon", "semicolon", "minus", "plus", "equal", "exclam", "exclamdown",
        "question", "questiondown", "apostrophe", "quotedbl", "slash", "backslash", "parenleft",
        "parenright", "bracketleft", "bracketright", "acute", "grave", "dead_acute", "dead_grave",
        "dead_tilde", "dead_circumflex", "dead_diaeresis", "underscore", "asterisk", "ampersand",
        "percent", "dollar", "numbersign", "at", "less", "greater", "quoteleft", "quoteright",
        "guillemotleft", "guillemotright", "masculine", "ordfeminine", "degree",
    ]
    /// ntilde, eacute, Ccedilla…: a letter with an accent on it.
    private static func accentedLetter(_ key: String) -> Bool {
        guard key.count > 1, let first = key.first, first.isLetter else { return false }
        return ["tilde", "acute", "grave", "cedilla", "diaeresis", "circumflex", "ring"].contains { key.hasSuffix($0) }
    }
    private static let leftLetters: Set<Character> = Set("qwertasdfgzxcvb12345")
    private static let rightLetters: Set<Character> = Set("yuiophjklnm67890")

    private static func classify(_ key: String) -> (Keys.Hand, Keys.Kind) {
        if key == "space" || key == " " { return (.thumb, .space) }
        if key.count == 1, let c = key.lowercased().first {
            let hand: Keys.Hand = leftLetters.contains(c) ? .left : rightLetters.contains(c) ? .right : .other
            if c.isLetter { return (hand, .letter) }
            if c.isNumber { return (hand, .digit) }
            return (.other, .punctuation)
        }
        if punctuationNames.contains(key) { return (.other, .punctuation) }
        if accentedLetter(key) { return (.other, .letter) }
        switch key {
        case "BackSpace": return (.other, .backspace)
        case "Return", "KP_Enter": return (.other, .enter)
        case "Tab": return (.other, .tab)
        case "Escape": return (.other, .escape)
        case "Left", "Right", "Up", "Down", "Home", "End", "Prior", "Next": return (.other, .navigation)
        default: return (.other, .other)
        }
    }

    // MARK: - The arithmetic

    /// Area under the ROC curve by rank: the chance a random case scores
    /// above a random control, ties counted half.
    static func auc(_ scores: [(score: Double, positive: Bool)]) -> Double? {
        let positives = scores.filter { $0.positive }.map { $0.score }
        let negatives = scores.filter { !$0.positive }.map { $0.score }
        guard !positives.isEmpty, !negatives.isEmpty else { return nil }
        var wins = 0.0
        for p in positives {
            for n in negatives {
                if p > n { wins += 1 } else if p == n { wins += 0.5 }
            }
        }
        return wins / Double(positives.count * negatives.count)
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count > 2 else { return nil }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    func testTheAUCArithmeticReproducesThePapersOwnIndex() throws {
        let cohort = try subjects()
        let scored = cohort.compactMap { s in s.nqi.map { (score: $0, positive: s.pd) } }
        let auc = try XCTUnwrap(Self.auc(scored))
        print("replay: \(cohort.count) subjects, \(cohort.filter(\.pd).count) PD; published nQi AUC = \(String(format: "%.3f", auc))")
        // The paper reports 0.81 on the combined dataset.
        XCTAssertEqual(auc, 0.81, accuracy: 0.03)
    }

    func testTheWindowCodeReproducesTheLogFluctuationIndex() throws {
        let cohort = try subjects()
        var byWindow: [(score: Double, positive: Bool)] = []
        var bySession: [(score: Double, positive: Bool)] = []
        var holdMedian: [(score: Double, positive: Bool)] = []
        var ours: [Double] = [], theirs: [Double] = []
        var windows = 0, valid = 0
        for subject in cohort {
            var fluctSDs: [Double] = []
            var sessionSDs: [Double] = []
            var medians: [Double] = []
            for session in subject.presses {
                var window = HoldWindow()
                var stats: [WindowStats] = []
                for press in session {
                    if let closed = window.add(press) { stats.append(closed) }
                }
                if let closed = window.close() { stats.append(closed) }
                windows += stats.count
                let good = stats.filter(\.valid)
                valid += good.count
                fluctSDs.append(contentsOf: good.compactMap { $0.fluct.sd })
                medians.append(contentsOf: good.map { $0.holdQ[3] })
                // Lan & Yeo: one SD over the whole session's successive
                // log ratios, no windowing.
                let typing = session.filter { $0.isTyping && ($0.hold ?? 0) > 0 && ($0.hold ?? 9) <= HoldWindow.holdCeiling }
                var m = Moments()
                for i in 1..<max(1, typing.count) { m.add(log(typing[i].hold! / typing[i - 1].hold!)) }
                if let sd = m.sd { sessionSDs.append(sd) }
            }
            guard !fluctSDs.isEmpty, !sessionSDs.isEmpty else { continue }
            let w = fluctSDs.reduce(0, +) / Double(fluctSDs.count)
            let s = sessionSDs.reduce(0, +) / Double(sessionSDs.count)
            byWindow.append((w, subject.pd))
            bySession.append((s, subject.pd))
            holdMedian.append((medians.reduce(0, +) / Double(max(1, medians.count)), subject.pd))
            if let nqi = subject.nqi {
                ours.append(w)
                theirs.append(nqi)
            }
        }
        let aucWindow = try XCTUnwrap(Self.auc(byWindow))
        let aucSession = try XCTUnwrap(Self.auc(bySession))
        let aucMedian = try XCTUnwrap(Self.auc(holdMedian))
        let r = Self.pearson(ours, theirs) ?? .nan
        print(String(format: "replay: %d windows, %d valid; AUC window fluct SD = %.3f, session fluct SD = %.3f, hold median = %.3f; r(window SD, nQi) = %.2f",
                     windows, valid, aucWindow, aucSession, aucMedian, r))
        // Lan & Yeo report 0.741 (CI 0.628–0.835) for the session-level SD
        // on 76 of these subjects; the window mean should land in the same
        // country, and the raw median hold should not.
        XCTAssertEqual(aucSession, 0.74, accuracy: 0.08)
        XCTAssertGreaterThan(aucWindow, 0.65)
        XCTAssertGreaterThan(valid, 500)
        // nQi is an ensemble regression score, not a linear function of the
        // fluctuation; the two agree on who is who (the AUCs above), not
        // on a line. Direction is all that is asked of the correlation.
        XCTAssertGreaterThan(r, 0, "the window index should at least point the paper's way")
    }
}
