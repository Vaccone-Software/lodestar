import AVFoundation
import Foundation
import LodestarCore
import Speech
import LodestarEars

/// Dictation, measured the way the draft does it.
///
///   probe dictation transcribe --manifest m.json --out runs.jsonl [--root dir] [--ids a,b]
///       Each item's audio through SpeechTranscriber with the draft's own
///       settings (volatile + fast results, word times and confidence),
///       fed as fast as it goes (finals are the same as at real time,
///       measured on 175 items). One JSON line per item: its results.
///
///   probe dictation settle --runs runs.jsonl --out hyps.json [--words names.txt] [--raw]
///       The results through the draft's own pipeline (`Draft.Settler`):
///       names by sound, seams, fillers, corrections, casing. `--raw`
///       joins finals as they came, for a baseline. Score with
///       scripts/dictation-eval/score.py.
///
///   probe dictation ear --engine name --model dir --manifest m.json --out runs.jsonl [--context names.txt] [--root dir]
///       Each item through a settling ear (`EarFactory`), one result per
///       item with its words, in the same JSON lines `settle` reads, plus
///       the time each took after its audio ended.
///
///   probe dictation record --out dir [--corpus utterances.json] [--from n01]
///       Reads the test sentences to you one at a time and records each
///       (16 kHz mono WAV), writing a manifest the scorer reads.
///
/// `--words` is one term per line; `Term = sounds like` gives a
/// pronunciation when the spelling is no guide ("Xonar = Zonar").
func runDictation(_ args: inout [String]) {
    guard let sub = args.first else { dictationUsage(); exit(64) }
    args.removeFirst()
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--"), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
            options[String(a.dropFirst(2))] = args[i + 1]; i += 2
        } else {
            flags.insert(String(a.dropFirst(2))); i += 1
        }
    }
    switch sub {
    case "settle": dictationSettle(options, raw: flags.contains("raw"))
    case "transcribe": dictationTranscribe(options)
    case "record": dictationRecord(options)
    case "ear": dictationEar(options)
    case "phones":
        // probe dictation phones "super base" Supabase …: each phrase's
        // phones, and every phrase's distance to the first.
        let pronouncer = probePronouncer()
        CommonWords.frequentListURL = repoRoot.appendingPathComponent("packaging/common-words.txt")
        let phrases = args.filter { !$0.hasPrefix("--") }
        let first = pronouncer.phones(phrases.first ?? "")
        for phrase in phrases {
            let phones = pronouncer.phones(phrase)
            print(phrase, "=", phones.joined(separator: " "), "  d=", String(format: "%.3f", Pronouncer.distance(first, phones)),
                  "common:", CommonWords.isCommon(phrase.lowercased()), "frequent:", CommonWords.isFrequent(phrase.lowercased()))
        }
    default: dictationUsage(); exit(64)
    }
}

private func dictationUsage() {
    print("""
    probe dictation transcribe --manifest m.json --out runs.jsonl [--root dir] [--ids a,b]
    probe dictation settle --runs runs.jsonl --out hyps.json [--words names.txt] [--raw]
    probe dictation record --out dir [--corpus utterances.json] [--from id]
    """)
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The draft's pronouncer, from the dictionary the app ships.
func probePronouncer() -> Pronouncer {
    let path = repoRoot.appendingPathComponent("packaging/cmudict.dict").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write("dictation: no \(path), spelling rules only\n".data(using: .utf8)!)
        return Pronouncer()
    }
    return Pronouncer(cmu: text)
}

func loadTerms(_ path: String?) -> [NameMatcher.Term] {
    guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let term = parts.first, !term.isEmpty, !term.hasPrefix("#") else { return nil }
        return NameMatcher.Term(term, soundsLike: parts.count > 1 ? [parts[1]] : [])
    }
}

// MARK: - Settle

private func dictationSettle(_ options: [String: String], raw: Bool) {
    guard let runs = options["runs"], let out = options["out"] else { dictationUsage(); exit(64) }
    let terms = loadTerms(options["words"])
    let pronouncer = probePronouncer()
    CommonWords.frequentListURL = repoRoot.appendingPathComponent("packaging/common-words.txt")
    CommonWords.warm()
    let matcher = terms.isEmpty ? nil : NameMatcher(terms: terms, pronouncer: pronouncer,
                                                    isCommon: { CommonWords.isCommon($0) },
                                                    isFrequent: { CommonWords.isFrequent($0) })
    // --repo: the repository's names, as the draft reads them for a
    // terminal or an editor in front.
    let codeNames = options["repo"].map { path -> CodeNames.Index in
        let names = CodeNames.gather(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        return CodeNames.Index(names: names, pronouncer: pronouncer)
    }
    if let codeNames { print("settle: \(codeNames.count) code names") }
    guard let text = try? String(contentsOfFile: runs, encoding: .utf8) else { print("settle: cannot read \(runs)"); exit(66) }
    var hyps: [String: String] = [:]
    var totals = [String: Int]()
    for line in text.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = item["id"] as? String, let events = item["events"] as? [[String: Any]] else { continue }
        let finals = events.filter { $0["fin"] as? Bool == true }.map(heard)
        if raw {
            hyps[id] = finals.map(\.text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .joined(separator: " ")
            continue
        }
        var settler = Draft.Settler(matcher: matcher, isOrdinary: { CommonWords.isCommon($0) })
        settler.codeNames = codeNames
        var buffer = ""
        var lastRange: Range<String.Index>?
        for final in finals where !final.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let landing = settler.land(final, after: buffer)
            for (key, value) in [("names", landing.names), ("code", landing.codeNames), ("ellipses", landing.ellipses), ("joins", landing.joins),
                                 ("fillers", landing.fillers), ("corrections", landing.corrections)] {
                totals[key, default: 0] += value
            }
            if landing.replacesLast, let range = lastRange {
                buffer.replaceSubrange(range, with: landing.text)
                lastRange = buffer.index(range.lowerBound, offsetBy: 0)..<buffer.endIndex
                continue
            }
            switch landing.before {
            case .dropPeriod:
                while buffer.last?.isWhitespace == true { buffer.removeLast() }
                if buffer.last == "." { buffer.removeLast() }
            case .addPeriod:
                while buffer.last?.isWhitespace == true { buffer.removeLast() }
                buffer += "."
            case .unchanged: break
            }
            let separator = buffer.isEmpty ? "" : Draft.separator(after: Array(buffer), before: landing.text)
            buffer += separator
            let start = buffer.endIndex
            buffer += landing.text
            lastRange = start..<buffer.endIndex
        }
        hyps[id] = buffer
    }
    let data = try! JSONSerialization.data(withJSONObject: hyps, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: out))
    print("settle: \(hyps.count) items -> \(out)  \(totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
}

private func heard(_ event: [String: Any]) -> Heard {
    let text = event["text"] as? String ?? ""
    let runs = (event["runs"] as? [[String: Any]]) ?? []
    let words: [Heard.Word] = runs.map { run in
        Heard.Word(run["t"] as? String ?? "", start: run["s"] as? Double, end: run["e"] as? Double,
                   confidence: run["c"] as? Double)
    }
    if words.isEmpty, let rs = event["rs"] as? Double, let re = event["re"] as? Double {
        return Heard(text, words: [Heard.Word(text, start: rs, end: re)])
    }
    return Heard(text, words: words)
}

// MARK: - Transcribe

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func dictationTranscribe(_ options: [String: String]) {
    guard let manifestPath = options["manifest"], let out = options["out"] else { dictationUsage(); exit(64) }
    let root = options["root"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = manifest["items"] as? [[String: Any]] else { print("transcribe: bad manifest"); exit(66) }
    let wanted = options["ids"].map { Set($0.split(separator: ",").map(String.init)) }
    let chosen = items.compactMap { item -> (String, URL)? in
        guard let id = item["id"] as? String, let file = item["file"] as? String else { return nil }
        if let wanted, !wanted.contains(id) { return nil }
        return (id, root.appendingPathComponent(file))
    }
    let done = DispatchSemaphore(value: 0)
    Task {
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = FileHandle(forWritingAtPath: out)!
        for (n, (id, url)) in chosen.enumerated() {
            do {
                guard #available(macOS 26, *) else { print("transcribe: needs macOS 26"); exit(69) }
                let events = try await transcribe(url)
                let line = try JSONSerialization.data(withJSONObject: ["id": id, "events": events])
                handle.write(line); handle.write("\n".data(using: .utf8)!)
                let finals = events.filter { $0["fin"] as? Bool == true }.count
                FileHandle.standardError.write("[\(n + 1)/\(chosen.count)] \(id) finals=\(finals)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("transcribe \(id): \(error)\n".data(using: .utf8)!)
            }
        }
        try? handle.close()
        done.signal()
    }
    done.wait()
}

/// One file through the draft's own transcriber settings, results as the
/// probe's JSON: text, final or not, and per-word times and confidence.
@available(macOS 26, *)
private func transcribe(_ url: URL) async throws -> [[String: Any]] {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no supported locale"])
    }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults],
                                        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    if await AssetInventory.status(forModules: [transcriber]) != .installed,
       let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
    let events = Box<[[String: Any]]>([])
    let reader = Task {
        for try await result in transcriber.results {
            var runs: [[String: Any]] = []
            for run in result.text.runs {
                var d: [String: Any] = ["t": String(result.text[run.range].characters)]
                if let range = run.audioTimeRange {
                    if range.start.isNumeric { d["s"] = range.start.seconds }
                    if range.end.isNumeric { d["e"] = range.end.seconds }
                }
                if let c = run.transcriptionConfidence { d["c"] = c }
                runs.append(d)
            }
            events.value.append(["text": String(result.text.characters), "fin": result.isFinal, "runs": runs])
        }
    }
    let file = try AVAudioFile(forReading: url)
    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    _ = try await reader.value
    return events.value
}

// MARK: - Ear

/// A WAV file as 16 kHz mono floats, the ears' input.
func samples16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let source = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return [] }
    try file.read(into: input)
    if source.sampleRate == 16_000, source.channelCount == 1, source.commonFormat == .pcmFormatFloat32 {
        return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
    }
    guard let converter = AVAudioConverter(from: source, to: target),
          let output = AVAudioPCMBuffer(pcmFormat: target,
                                        frameCapacity: AVAudioFrameCount(Double(frames) * 16_000 / source.sampleRate) + 1024)
    else { return [] }
    var given = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

private func dictationEar(_ options: [String: String]) {
    guard let engine = options["engine"], let model = options["model"], let manifestPath = options["manifest"],
          let out = options["out"] else { dictationUsage(); exit(64) }
    guard let ear = EarFactory.make(engine, folder: URL(fileURLWithPath: (model as NSString).expandingTildeInPath)) else {
        print("ear: no engine \(engine)"); exit(64)
    }
    let root = options["root"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
    let context = options["context"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
        .split(separator: "\n").map { $0.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") } ?? []
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = manifest["items"] as? [[String: Any]] else { print("ear: bad manifest"); exit(66) }
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let began = Date()
            try await ear.load()
            FileHandle.standardError.write("ear: \(ear.name) loaded in \(String(format: "%.1f", Date().timeIntervalSince(began))) s\n".data(using: .utf8)!)
            FileManager.default.createFile(atPath: out, contents: nil)
            let handle = FileHandle(forWritingAtPath: out)!
            for (n, item) in items.enumerated() {
                guard let id = item["id"] as? String, let file = item["file"] as? String else { continue }
                let audio = try samples16k(root.appendingPathComponent(file))
                let start = Date()
                let heard = try await ear.transcribe(audio, context: context)
                let seconds = Date().timeIntervalSince(start)
                let runs: [[String: Any]] = heard.words.map { word in
                    var d: [String: Any] = ["t": word.text]
                    if let s = word.start { d["s"] = s }
                    if let e = word.end { d["e"] = e }
                    if let c = word.confidence { d["c"] = c }
                    return d
                }
                let line: [String: Any] = ["id": id, "seconds": seconds, "audio": Double(audio.count) / 16_000,
                                           "events": [["text": heard.text, "fin": true, "runs": runs]]]
                handle.write(try JSONSerialization.data(withJSONObject: line))
                handle.write("\n".data(using: .utf8)!)
                FileHandle.standardError.write("[\(n + 1)/\(items.count)] \(id) \(String(format: "%.3f", seconds)) s\n".data(using: .utf8)!)
            }
            try? handle.close()
        } catch {
            print("ear: \(error)")
        }
        done.signal()
    }
    done.wait()
}

// MARK: - Record

private func dictationRecord(_ options: [String: String]) {
    guard let outDir = options["out"] else { dictationUsage(); exit(64) }
    let corpusPath = options["corpus"]
        ?? repoRoot.appendingPathComponent("scripts/dictation-eval/corpus/utterances.json").path
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: corpusPath)),
          let utterances = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        print("record: cannot read \(corpusPath)"); exit(66)
    }
    let out = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: out.appendingPathComponent("audio"), withIntermediateDirectories: true)
    let manifestURL = out.appendingPathComponent("manifest.json")
    var items: [[String: Any]] = []
    if let old = try? Data(contentsOf: manifestURL),
       let parsed = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
       let kept = parsed["items"] as? [[String: Any]] { items = kept }
    var started = options["from"] == nil
    let granted = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in granted.signal() }
    granted.wait()
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("record: the microphone is not allowed for this terminal (System Settings → Privacy → Microphone)")
        exit(77)
    }
    print("""
    Read each sentence as you would dictate it. Where it says [pause], stop
    and think for about two seconds, then carry on. Say the names the way
    you always do. ⏎ starts a recording, ⏎ again stops it; s skips; q quits
    (everything recorded so far is kept).
    """)
    for (n, utterance) in utterances.enumerated() {
        guard let uid = utterance["utterance_id"] as? String else { continue }
        if !started { started = uid == options["from"]; if !started { continue } }
        let source = (utterance["source_text"] as? String) ?? (utterance["reference_verbatim"] as? String ?? "")
        let shown = source.replacingOccurrences(of: #"\{p\d+\}"#, with: "[pause]", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        print("\n[\(n + 1)/\(utterances.count)] \(uid) (\(utterance["category"] as? String ?? ""))\n  \(shown)")
        print("  ⏎ to start, s to skip, q to quit: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "q"
        if answer == "q" { break }
        if answer == "s" { continue }
        let id = "\(uid)__you"
        let file = "audio/\(id).wav"
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let recorder = try? AVAudioRecorder(url: out.appendingPathComponent(file), settings: settings) else {
            print("record: could not open the microphone"); exit(70)
        }
        recorder.record()
        print("  ● recording, ⏎ to stop: ", terminator: "")
        _ = readLine()
        let seconds = recorder.currentTime
        recorder.stop()
        print("  saved \(String(format: "%.1f", seconds)) s")
        var item = utterance
        item.removeValue(forKey: "tts_text")
        // Where the pauses fall, by the word they follow, as the scorer
        // counts them: the words of the sentence before each {pNNNN}.
        var pauses: [[String: Any]] = []
        let marker = try! NSRegularExpression(pattern: #"\{p(\d+)\}"#)
        let ns = source as NSString
        for match in marker.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: match.range.location)
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
            let words = before.split(whereSeparator: \.isWhitespace).count
            let ms = Int(ns.substring(with: match.range(at: 1))) ?? 0
            pauses.append(["kind": "mid", "after_token": words - 1, "ms": ms])
        }
        if !pauses.isEmpty { item["pauses"] = pauses }
        item["id"] = id
        item["file"] = file
        item["voice"] = "you"
        item["source"] = "recorded"
        items.removeAll { $0["id"] as? String == id }
        items.append(item)
        let manifest: [String: Any] = ["sample_rate": 16_000, "format": "WAV PCM 16-bit mono", "items": items]
        try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: manifestURL)
    }
    print("\n\(items.count) recordings in \(out.path). Thank you.")
}
