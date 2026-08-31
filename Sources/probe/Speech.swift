import AVFoundation
import Foundation
import Speech

/// `probe speech` — the questions the draft's shape depends on, asked of
/// the macOS 26 Speech framework before a line of the bar is written:
///
///   1. How long from "open" to the first volatile word? (model prepare,
///      audio-engine start, first result)
///   2. How do volatile results revise: does settled text ever change,
///      how many volatile updates precede a final one?
///   3. Does stopping the audio engine and restarting it (the mic falling
///      silent in normal mode) cost a fresh warm-up?
///   4. Do contextual strings actually land a word the model would
///      otherwise miss ("Ghostty", "Lodestar")?
///   5. SpeechTranscriber vs DictationTranscriber: which one punctuates,
///      and which one is quicker to the first word.
///   6. Does any of it need the speech-recognition TCC grant, or only the
///      microphone?
///
/// Speak into the mic while it runs; the run prints every result with
/// its age and a summary at the end.
func runSpeech(_ args: inout [String]) {
    guard #available(macOS 26, *) else {
        print("probe speech: needs macOS 26 (SpeechAnalyzer)")
        exit(1)
    }
    var seconds = 20.0
    var words: [String] = []
    var dictation = false
    var cycle = false
    var requestSpeechAuth = false
    var file: String?
    var onMain = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--seconds": i += 1; seconds = Double(args[i]) ?? seconds
        case "--words": i += 1; words = args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        case "--dictation": dictation = true
        case "--cycle": cycle = true
        case "--auth": requestSpeechAuth = true
        case "--file": i += 1; file = args[i]
        case "--main": onMain = true
        default: print("probe speech: unknown flag \(args[i])"); exit(2)
        }
        i += 1
    }
    let probe = SpeechProbe(seconds: seconds, words: words, dictation: dictation,
                            cycle: cycle, requestSpeechAuth: requestSpeechAuth, file: file)
    probe.onMain = onMain
    Task {
        do { try await probe.run() } catch { print("✕ \(error)") }
        exit(0)
    }
    RunLoop.main.run()
}

@available(macOS 26, *)
final class SpeechProbe: @unchecked Sendable {
    let seconds: Double
    let words: [String]
    let dictation: Bool
    let cycle: Bool
    let requestSpeechAuth: Bool
    /// An audio file streamed at real-time pace instead of the microphone,
    /// so revision behavior and vocabulary can be measured unattended.
    let file: String?
    /// Create and start the engine on the main thread, the way the app does.
    var onMain = false

    private let t0 = Date()
    private var firstAudioAt: Date?
    private var firstResultAt: Date?
    private var restartAt: Date?
    private var firstResultAfterRestartAt: Date?
    private var volatileCount = 0
    private var finalCount = 0
    private var revisions = 0
    private var lastTextByStart: [Double: String] = [:]
    private var settled: [(start: Double, text: String)] = []
    private var settledChangedLater = 0
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    init(seconds: Double, words: [String], dictation: Bool, cycle: Bool, requestSpeechAuth: Bool, file: String?) {
        self.seconds = seconds; self.words = words; self.dictation = dictation
        self.cycle = cycle; self.requestSpeechAuth = requestSpeechAuth; self.file = file
    }

    private func age() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
    private func log(_ s: String) { print("\(age())  \(s)"); fflush(stdout) }

    func run() async throws {
        let locale = Locale.current
        log("locale \(locale.identifier)  module \(dictation ? "DictationTranscriber" : "SpeechTranscriber")  words \(words)")
        log("SFSpeechRecognizer auth status before: \(SFSpeechRecognizer.authorizationStatus().rawValue) (0 notDetermined 1 denied 2 restricted 3 authorized)")
        if requestSpeechAuth {
            let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            log("requested speech auth → \(status.rawValue)")
        }

        // 1. module + assets
        let module: any SpeechModule
        if dictation {
            guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                log("✕ DictationTranscriber: locale unsupported"); return
            }
            module = DictationTranscriber(
                locale: loc, contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [.audioTimeRange])
        } else {
            log("SpeechTranscriber.isAvailable \(SpeechTranscriber.isAvailable)")
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                log("✕ SpeechTranscriber: locale unsupported"); return
            }
            module = SpeechTranscriber(
                locale: loc, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange])
        }
        let status = await AssetInventory.status(forModules: [module])
        log("asset status \(status)")
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                log("downloading model assets…")
                let progress = request.progress
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        self.log(String(format: "  %.0f%%", progress.fractionCompleted * 100))
                    }
                }
                try await request.downloadAndInstall()
                ticker.cancel()
                log("assets installed")
            }
        }

        // 2. microphone (unless a file stands in for it)
        if file == nil {
            let micBefore = AVCaptureDevice.authorizationStatus(for: .audio)
            log("mic auth before: \(micBefore.rawValue) (0 notDetermined 1 restricted 2 denied 3 authorized)")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            log("mic granted \(granted)")
            guard granted else { return }
        }

        // 3. analyzer
        let context = AnalysisContext()
        if !words.isEmpty { context.contextualStrings[.general] = words }
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.setContext(context)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        log("analyzer format \(format.map { "\($0.sampleRate)Hz ch\($0.channelCount) \($0.commonFormat.rawValue)" } ?? "nil")")
        analyzerFormat = format
        let prepStart = Date()
        try await analyzer.prepareToAnalyze(in: format)
        log(String(format: "prepareToAnalyze took %.0fms", Date().timeIntervalSince(prepStart) * 1000))

        // 4. results
        let resultsTask: Task<Void, Never>
        if let t = module as? SpeechTranscriber {
            resultsTask = Task { [weak self] in
                do { for try await r in t.results { self?.note(text: String(r.text.characters), range: r.range, final: r.isFinal) } }
                catch { self?.log("results stream ended: \(error)") }
            }
        } else if let d = module as? DictationTranscriber {
            resultsTask = Task { [weak self] in
                do { for try await r in d.results { self?.note(text: String(r.text.characters), range: r.range, final: r.isFinal) } }
                catch { self?.log("results stream ended: \(error)") }
            }
        } else { return }

        // 5. audio
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        try await analyzer.start(inputSequence: stream)
        if let file {
            try await streamFile(file, into: cont)
        } else {
            try startEngine()
            log("listening for \(Int(seconds))s — speak now" + (words.isEmpty ? "" : "; say the words: \(words.joined(separator: ", "))"))
        }

        if file != nil {
            // The file has been streamed; give the analyzer a beat.
            try await Task.sleep(for: .milliseconds(500))
        } else if cycle {
            try await Task.sleep(for: .seconds(seconds * 0.4))
            log("— stopping the audio engine (normal-mode silence) —")
            stopEngine()
            try await Task.sleep(for: .seconds(1.5))
            restartAt = Date()
            log("— restarting the audio engine —")
            try startEngine()
            try await Task.sleep(for: .seconds(seconds * 0.6))
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }

        // 6. finish
        stopEngine()
        cont.finish()
        let finStart = Date()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        log(String(format: "finalize took %.0fms", Date().timeIntervalSince(finStart) * 1000))
        try? await Task.sleep(for: .milliseconds(300))
        resultsTask.cancel()
        summary()
    }

    /// Stream a file in 100ms slices at real-time pace, the way a mic
    /// would deliver it, converted to the analyzer's format.
    private func streamFile(_ path: String, into cont: AsyncStream<AnalyzerInput>.Continuation) async throws {
        let url = URL(fileURLWithPath: path)
        let audio = try AVAudioFile(forReading: url)
        guard let outFormat = analyzerFormat,
              let converter = AVAudioConverter(from: audio.processingFormat, to: outFormat) else {
            throw NSError(domain: "probe", code: 2)
        }
        let total = Double(audio.length) / audio.processingFormat.sampleRate
        log(String(format: "streaming %@ (%.1fs) at real-time pace", url.lastPathComponent, total))
        let sliceFrames = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        var streamedFrames: AVAudioFramePosition = 0
        let wall = Date()
        while streamedFrames < audio.length {
            guard let slice = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: sliceFrames) else { break }
            try audio.read(into: slice, frameCount: sliceFrames)
            if slice.frameLength == 0 { break }
            streamedFrames += AVAudioFramePosition(slice.frameLength)
            let ratio = outFormat.sampleRate / audio.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(slice.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { break }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return slice
            }
            if firstAudioAt == nil { firstAudioAt = Date() }
            if error == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
            // Real-time pacing: sleep until the wall clock catches up with the audio clock.
            let audioClock = Double(streamedFrames) / audio.processingFormat.sampleRate
            let ahead = audioClock - Date().timeIntervalSince(wall)
            if ahead > 0 { try await Task.sleep(for: .milliseconds(Int(ahead * 1000))) }
        }
        log("file streamed")
    }

    private func startEngine() throws {
        if onMain, !Thread.isMainThread {
            var thrown: Error?
            DispatchQueue.main.sync { do { try self.startEngine() } catch { thrown = error } }
            if let thrown { throw thrown }
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        log("formats: output \(inFormat.sampleRate)Hz ch\(inFormat.channelCount)  input \(input.inputFormat(forBus: 0).sampleRate)Hz  main=\(Thread.isMainThread)")
        guard let outFormat = analyzerFormat else { throw NSError(domain: "probe", code: 1) }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        let startedAt = Date()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter, let cont = self.continuation else { return }
            if self.firstAudioAt == nil {
                self.firstAudioAt = Date()
                self.log(String(format: "first audio buffer %.0fms after engine start", Date().timeIntervalSince(startedAt) * 1000))
            }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        log(String(format: "engine.start took %.0fms (input %.0fHz ch%d)", Date().timeIntervalSince(startedAt) * 1000, inFormat.sampleRate, inFormat.channelCount))
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func note(text: String, range: CMTimeRange, final: Bool) {
        let now = Date()
        if firstResultAt == nil {
            firstResultAt = now
            if let a = firstAudioAt {
                log(String(format: "FIRST RESULT %.0fms after first audio", now.timeIntervalSince(a) * 1000))
            }
        }
        if let r = restartAt, firstResultAfterRestartAt == nil, now > r {
            firstResultAfterRestartAt = now
            log(String(format: "first result after restart: %.0fms", now.timeIntervalSince(r) * 1000))
        }
        let start = range.start.seconds
        if final {
            finalCount += 1
            settled.append((start, text))
        } else {
            volatileCount += 1
            if let prev = lastTextByStart[start], prev != text { revisions += 1 }
            lastTextByStart[start] = text
            // Does a volatile result ever reach back into already-settled audio?
            if let lastSettled = settled.last, start < lastSettled.start + 0.001 {
                settledChangedLater += 1
            }
        }
        log(String(format: "%@ [%5.2f→%5.2f] %@", final ? "FINAL   " : "volatile", start, range.end.seconds, text))
    }

    private func summary() {
        print("\n— summary —")
        if let a = firstAudioAt, let r = firstResultAt {
            print(String(format: "first result after first audio: %.0fms", r.timeIntervalSince(a) * 1000))
        } else { print("no results received") }
        if let r = restartAt {
            if let f = firstResultAfterRestartAt {
                print(String(format: "first result after engine restart: %.0fms", f.timeIntervalSince(r) * 1000))
            } else { print("no result after engine restart") }
        }
        print("volatile results \(volatileCount), final results \(finalCount), volatile revisions \(revisions), volatile results reaching into settled audio \(settledChangedLater)")
        let transcript = settled.map(\.text).joined(separator: " ")
        print("settled transcript: \(transcript)")
        if !words.isEmpty {
            for w in words {
                let hit = transcript.range(of: w, options: .caseInsensitive) != nil
                print("  word \(w): \(hit ? "✓ recognized" : "✕ not found")")
            }
        }
        print("SFSpeechRecognizer auth status after: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
    }
}
