import AVFoundation
import Foundation
import LodestarCore
import Speech

/// What the recognizer is doing, for the register line to say.
enum SpeechState: Equatable {
    /// The model is being fetched or loaded; `progress` when known.
    case preparing(progress: Double?)
    /// Audio is flowing from `input` (the device's name) to the recognizer.
    case listening(input: String?)
    case paused
    /// The microphone grant was refused; the draft types only.
    case denied
    /// No recognizer on this machine (macOS before 26, or no locale model).
    case unavailable
    case failed(String)
}

/// The recognizer behind the draft's speak door: one session per draft,
/// results on the main thread, and a pause that keeps the audio engine
/// warm (creating one costs a second; starting a kept one costs 70ms —
/// `probe speech --cycle` measured both). The engine itself lives on its
/// own queue: the main thread hosts the event tap, and a start that
/// waits out a Bluetooth profile flip held it long enough for macOS to
/// disable the tap — three times in one day's log.
protocol SpeechSession: AnyObject {
    var isAvailable: Bool { get }
    /// Load the model and build the audio engine without touching the
    /// microphone, so a first `lode .` after boot does not pay for either.
    /// Called only once the grant exists.
    func warm(input: String?)
    /// Begin a session. `words` are the user's vocabulary, offered to the
    /// recognizer as context (SpeechTranscriber ignores them today, the
    /// probe found; the draft repairs tokens itself either way).
    func listen(words: [String], input: String?,
                onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float) -> Void,
                onVolatile: @escaping (String) -> Void,
                onSettled: @escaping (String) -> Void)
    /// The mic goes quiet, the session stays. Normal mode.
    func pause()
    func resume()
    /// End the session; `completion` runs once the last words have settled
    /// (or the recognizer gave up on them).
    func stop(completion: @escaping () -> Void)
    /// Stream an audio file into the live session at real-time pace, as
    /// if the microphone heard it. False when there is no session.
    func feed(file: URL) -> Bool
}

/// The Speech framework's on-device analyzer. macOS 26 only; every entry
/// point is availability-gated so the binary still links on 13.
final class AnalyzerSpeechSession: SpeechSession {
    fileprivate var box: Any?
    /// One microphone for the process: creating an engine costs a second,
    /// starting a kept one costs 70ms. Every call on it lands on its one
    /// serial queue, in the order it was made — two sessions overlapping
    /// on one bus was a crash inside `installTapOnBus`.
    private let microphone = AudioInput()

    var isAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    func warm(input: String?) {
        guard #available(macOS 26, *) else { return }
        microphone.prepare(device: input)
        Task { await AnalyzerBox.warm() }
    }

    func listen(words: [String], input: String?,
                onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float) -> Void,
                onVolatile: @escaping (String) -> Void,
                onSettled: @escaping (String) -> Void) {
        guard #available(macOS 26, *) else { onState(.unavailable); return }
        // A session still winding down must let go of the bus first, and
        // one still preparing must be told it lost, or two would race for
        // the microphone and the loser would leak.
        microphone.stop()
        if let old = box as? AnalyzerBox { Task { await old.stop() } }
        let box = AnalyzerBox(microphone: microphone)
        self.box = box
        Task { await box.listen(words: words, input: input,
                                stillWanted: { [weak self] in (self?.box as AnyObject?) === box },
                                onState: onState, onLevel: onLevel,
                                onVolatile: onVolatile, onSettled: onSettled) }
    }

    func pause() {
        microphone.pause()
    }

    func resume() {
        microphone.resume()
    }

    func stop(completion: @escaping () -> Void) {
        guard #available(macOS 26, *), let box = box as? AnalyzerBox else { completion(); return }
        self.box = nil
        // The tap comes off first: queued now, ahead of anything the next
        // session queues, which may be before the recognizer has finished.
        microphone.stop()
        Task {
            await box.stop()
            await MainActor.run { completion() }
        }
    }
}

extension AnalyzerSpeechSession {
    func feed(file: URL) -> Bool {
        guard #available(macOS 26, *), let box = box as? AnalyzerBox else { return false }
        Task { await box.feed(file: file) }
        return true
    }
}

/// The process's one audio engine and the tap on its input. Everything
/// here runs on one serial queue, never the main thread: building an
/// engine costs a second, and a start inside a Bluetooth profile flip
/// fails slowly (-10868 after 400–800ms, measured) before it succeeds.
/// The main thread hosts the event tap, and macOS disables a tap whose
/// thread stops answering — every keystroke on the machine went dead
/// until the watchdog brought it back. The actor that consumes the
/// buffers never touches the engine directly.
final class AudioInput: @unchecked Sendable {
    /// The engine's queue. Calls made from the main thread keep their
    /// order here, so a stop queued before a start still lands first.
    private let queue = DispatchQueue(label: "com.vaccone.lodestar.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    /// The device the engine was built for, and the format it had then.
    /// An engine's input node fixes its formats to what it first saw;
    /// a different device, or the same device at a new sample rate (a
    /// capture box that renegotiates), leaves them stale — no buffers,
    /// or -10868 at start. Either way the engine is rebuilt; the same
    /// device at the same format keeps the warm one.
    private var engineDevice: AudioDeviceID?
    private var engineFormat: (rate: Double, channels: UInt32)?
    private var tapInstalled = false
    private var observer: NSObjectProtocol?
    /// The session in flight — the device asked for and the sink — kept
    /// so a configuration change can rebuild it. nil between sessions.
    private var inFlight: (device: String?, sink: (AVAudioPCMBuffer) -> Void)?
    /// Rebuilds this session has spent: a radio that keeps flipping must
    /// not rebuild forever.
    private var rebuilds = 0
    private var rebuildPending = false
    static let rebuildCap = 6
    /// Which engine a configuration-change notice was about: each build
    /// stamps the next number and observes its own engine by object, so
    /// a notice from an engine already discarded is dropped by number.
    private var engineGeneration = 0

    init() {}

    /// Watch `fresh` for the hardware under it changing.
    ///
    /// Nothing happens inside the notification: the center posts it from
    /// the engine's own IO-unit queue and WAITS for the observer to
    /// return, and any engine call from inside — prepare, start, stop —
    /// dispatches synchronously onto that same waiting queue. v0.28.0 did
    /// exactly that from the audio queue and deadlocked: every later
    /// draft's start queued behind it and the microphone never opened
    /// again until relaunch. So the block only hops. And it never touches
    /// the notification's object: the center also posts while an engine
    /// is being torn down, and retaining that object crashed the first
    /// build of 0.28.1 on release. Observed by object, the center does the
    /// matching; `discard` unregisters before the engine goes.
    private func observe(_ fresh: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engineGeneration += 1
        let generation = engineGeneration
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: fresh, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.configurationChanged(generation: generation) }
        }
    }

    /// The hardware under the engine moved. Mid-session the engine is
    /// restarted in place, tap and all — the path that delivered a
    /// thousand buffers a session on 0.27.0 — and a start caught inside
    /// the flip (-10868) is retried a beat later rather than abandoned,
    /// which is what left 0.27.0's failed restarts silent. Rebuilding on
    /// every change was tried first and cycled: each fresh engine drew a
    /// fresh change, and the tap came down every second. A rebuild is now
    /// the fallback when restarts keep failing. Idle, the engine is
    /// simply not trusted any more.
    private func configurationChanged(generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let engine, generation == engineGeneration else { return }
        guard inFlight != nil else {
            Log.info("draft", ["speech": "audio configuration changed", "idle": true])
            discard()
            return
        }
        if engine.isRunning {
            Log.info("draft", ["speech": "audio configuration changed", "running": true])
            return
        }
        guard !rebuildPending else { return }
        rebuildPending = true
        restart(attempt: 1)
    }

    private func restart(attempt: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard inFlight != nil, let engine else { rebuildPending = false; return }
        if engine.isRunning { rebuildPending = false; return }
        engine.prepare()
        do {
            try engine.start()
            rebuildPending = false
            Log.info("draft", ["speech": "audio configuration changed", "restarted": true, "attempt": attempt])
        } catch {
            Log.info("draft", ["speech": "audio configuration changed",
                               "restart failed": error.localizedDescription, "attempt": attempt])
            guard attempt < 4 else {
                rebuildPending = false
                rebuild(attempt: 1)
                return
            }
            queue.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.restart(attempt: attempt + 1) }
        }
    }

    /// The fallback: a fresh engine for the session in flight, on the
    /// same sink, when the kept one will not start again. Bounded twice:
    /// attempts per change, rebuilds per session.
    private func rebuild(attempt: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let inFlight else { return } // the session ended while this waited
        guard rebuilds < Self.rebuildCap else {
            Log.info("draft", ["speech": "audio configuration changed", "rebuilds": rebuilds, "gaveUp": true])
            return
        }
        rebuilds += 1
        do {
            let started = try startNow(device: inFlight.device, sink: inFlight.sink, fresh: true)
            Log.info("draft", ["speech": "audio configuration changed", "rebuilt": true,
                               "attempt": attempt, "inHz": Int(started.format.sampleRate)])
        } catch {
            Log.info("draft", ["speech": "audio configuration changed",
                               "rebuild failed": error.localizedDescription, "attempt": attempt])
            guard attempt < 4 else { return }
            queue.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.rebuild(attempt: attempt + 1) }
        }
    }

    private func discard() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Unregistered first: a teardown posts the same notice, and no
        // block of ours may run for an engine on its way out.
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        engine = nil
        engineDevice = nil
        engineFormat = nil
        tapInstalled = false
    }

    private func build(for target: AudioDeviceID?) -> AVAudioEngine {
        dispatchPrecondition(condition: .onQueue(queue))
        let fresh = AVAudioEngine()
        // The device goes in before the node reports a format, so the
        // formats it fixes are this device's.
        if let target, let unit = fresh.inputNode.audioUnit { _ = Self.use(target, on: unit) }
        let format = fresh.inputNode.inputFormat(forBus: 0)
        observe(fresh)
        engine = fresh
        engineDevice = target
        engineFormat = (format.sampleRate, format.channelCount)
        return fresh
    }

    /// Every device with an input stream, by CoreAudio id and name.
    static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr,
                  streamBytes > 0, let name = name(of: id) else { return nil }
            return (id, name)
        }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name = value?.takeRetainedValue() else { return nil }
        return name as String
    }

    /// The system's default input right now.
    static func defaultInput() -> AudioDeviceID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The system's default input, by name, for the settings pane.
    static var defaultInputName: String? { defaultInput().flatMap(name(of:)) }

    private static func device(of unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func use(_ id: AudioDeviceID, on unit: AudioUnit) -> Bool {
        var device = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &device,
                                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// Install the tap and start the engine, reading from `device` by
    /// name when one is configured and found, the system default
    /// otherwise — set explicitly each time, so a kept engine follows a
    /// default that changed since. `sink` runs on the audio thread with
    /// each buffer in the input's native format. `completion` runs on
    /// the engine's queue with the format and the name of the device
    /// actually read, or the error: no usable format is what an
    /// unplugged or exclusively held device looks like.
    func start(device: String?, sink: @escaping (AVAudioPCMBuffer) -> Void,
               completion: @escaping (Result<(format: AVAudioFormat, name: String?), Error>) -> Void) {
        queue.async {
            self.rebuilds = 0
            completion(Result { try self.startNow(device: device, sink: sink) })
        }
    }

    /// `fresh` discards the kept engine first: a rebuild after a
    /// configuration change must not trust the node's own report of its
    /// format, which is what the stale check below reads.
    private func startNow(device: String?, sink: @escaping (AVAudioPCMBuffer) -> Void,
                          fresh: Bool = false) throws
        -> (format: AVAudioFormat, name: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        stopNow()
        inFlight = (device, sink)
        if fresh { discard() }
        let wanted = device.flatMap { name in Self.inputDevices().first { $0.name == name }?.id }
        if device != nil, wanted == nil {
            Log.info("draft", ["speech": "input not found", "wanted": device ?? ""])
        }
        let target = wanted ?? Self.defaultInput()
        var attempt = 0
        var format = AVAudioFormat()
        while true {
            // A kept engine serves only the device and format it was built
            // for; anything else, and any failed start, gets a fresh one.
            let current = engine?.inputNode.inputFormat(forBus: 0)
            let stale = engine == nil || engineDevice != target || attempt > 0
                || current.map { ($0.sampleRate, $0.channelCount) != (engineFormat?.rate, engineFormat?.channels) } ?? true
            if stale { discard(); _ = build(for: target) }
            guard let engine else { throw NSError(domain: "draft", code: 3) }
            let input = engine.inputNode
            // The hardware's format, not the node's output format; a nil
            // tap format takes whatever the node delivers, and the feed
            // converts per buffer, whatever arrives.
            format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "draft", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "the input has no usable format"])
            }
            // Small buffers: at 16 kHz, 4096 frames was a quarter second of
            // audio held back from the recognizer on every callback.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in sink(buffer) }
            tapInstalled = true
            engine.prepare()
            do {
                try engine.start()
                break
            } catch {
                discard()
                attempt += 1
                Log.info("draft", ["speech": "engine start failed", "attempt": attempt,
                                   "error": error.localizedDescription])
                if attempt > 1 { throw error }
            }
        }
        guard let engine else { throw NSError(domain: "draft", code: 3) }
        let input = engine.inputNode
        let name = input.audioUnit.flatMap(Self.device(of:)).flatMap(Self.name(of:))
        Log.info("draft", ["speech": "engine", "running": engine.isRunning,
                           "inHz": Int(input.inputFormat(forBus: 0).sampleRate),
                           "inCh": Int(input.inputFormat(forBus: 0).channelCount),
                           "voiceProcessing": input.isVoiceProcessingEnabled])
        return (format, name)
    }

    func pause() {
        queue.async { self.engine?.pause() }
    }

    func resume() {
        queue.async {
            guard self.tapInstalled, let engine = self.engine else { return }
            try? engine.start()
        }
    }

    /// Build the engine for the device the next session will read, without
    /// starting it: creation is the second-long part, starting is 70ms.
    func prepare(device: String?) {
        queue.async {
            guard self.engine == nil else { return }
            let wanted = device.flatMap { name in Self.inputDevices().first { $0.name == name }?.id }
            _ = self.build(for: wanted ?? Self.defaultInput())
        }
    }

    /// Take the tap off and stop the engine fully, so the next start can
    /// change the device: a paused graph keeps the device it had.
    /// Idempotent. The engine object is kept; starting it again is the
    /// 70ms path, creating one is the second.
    func stop() {
        queue.async { self.stopNow() }
    }

    private func stopNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        inFlight = nil
        guard let engine else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}

/// One session's analyzer, transcriber, audio tap, and result loop.
@available(macOS 26, *)
private actor AnalyzerBox {
    private let microphone: AudioInput
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var feed: AudioFeed?
    private var format: AVAudioFormat?
    private var stopped = false

    init(microphone: AudioInput) { self.microphone = microphone }

    private static let options = SpeechAnalyzer.Options(priority: .userInitiated,
                                                        modelRetention: .processLifetime)

    /// Load the locale's model into the process (retained for its
    /// lifetime) so the first real session prepares in ~100ms.
    static func warm() async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
        Log.info("draft", ["speech": "warm"])
    }

    func listen(words: [String], input wanted: String?,
                stillWanted: @escaping @MainActor () -> Bool,
                onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float) -> Void,
                onVolatile: @escaping (String) -> Void,
                onSettled: @escaping (String) -> Void) async {
        let say: (SpeechState) -> Void = { state in
            Log.info("draft", ["speech": "\(state)"])
            Task { @MainActor in onState(state) }
        }
        Log.info("draft", ["speech": "start", "available": SpeechTranscriber.isAvailable,
                           "locale": Locale.current.identifier])
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            Log.info("draft", ["speech": "no supported locale"])
            say(.unavailable); return
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        self.transcriber = transcriber

        // The model, fetched once. Lazy on purpose: nothing downloads until
        // someone opens the door.
        let status = await AssetInventory.status(forModules: [transcriber])
        Log.info("draft", ["speech": "assets", "status": "\(status)"])
        if status == .unsupported { say(.unavailable); return }
        if status != .installed {
            say(.preparing(progress: 0))
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let progress = request.progress
                    let ticker = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(500))
                            say(.preparing(progress: progress.fractionCompleted))
                        }
                    }
                    defer { ticker.cancel() }
                    try await request.downloadAndInstall()
                    Log.info("draft", ["speech": "assets installed"])
                } else {
                    Log.info("draft", ["speech": "no installation request offered"])
                }
            } catch {
                Log.info("draft", ["speech": "asset install failed", "error": "\(error)"])
                say(.failed("the speech model could not be installed")); return
            }
        }

        // The grant, asked at the moment of use and never before.
        Log.info("draft", ["speech": "asking for the microphone",
                           "status": AVCaptureDevice.authorizationStatus(for: .audio).rawValue])
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        Log.info("draft", ["speech": "microphone", "granted": granted])
        guard granted else { say(.denied); return }
        guard !stopped else { return }

        let context = AnalysisContext()
        if !words.isEmpty { context.contextualStrings[.general] = words }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.options)
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.format = format
        do {
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            Log.info("draft", ["speech": "prepare failed", "error": "\(error)"])
            say(.failed("the recognizer could not start")); return
        }

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        await MainActor.run { onSettled(text) }
                    } else {
                        await MainActor.run { onVolatile(text) }
                    }
                }
            } catch {
                await self?.noteResultsEnded(error)
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        guard let outFormat = format else { say(.failed("the recognizer has no audio format")); return }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            Log.info("draft", ["speech": "analyzer start failed", "error": "\(error)"])
            say(.failed("the recognizer could not start")); return
        }
        guard !stopped else { return }
        let feed = AudioFeed(outFormat: outFormat, continuation: continuation, onLevel: onLevel)
        self.feed = feed
        // A Bluetooth radio resting on its music profile flips to the
        // hands-free profile when the input opens, and a start inside the
        // flip fails with -10868 — measured on the headset this was built
        // against: the first start from the music profile always fails,
        // and one ~750ms later succeeds (longer while music actively
        // streams). The engine's own immediate rebuild cannot outwait
        // that, so the settling happens here, off the main thread,
        // across a few attempts.
        var started: (format: AVAudioFormat, name: String?)?
        for attempt in 1...4 {
            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(650))
                guard !stopped else { return }
            }
            do {
                started = try await Self.startMicrophone(microphone, device: wanted,
                                                         stillWanted: stillWanted) { buffer in feed.push(buffer) }
                break
            } catch is CancellationError {
                return
            } catch {
                Log.info("draft", ["speech": "audio start failed", "attempt": attempt,
                                   "error": "\(error.localizedDescription)"])
            }
        }
        guard let started else {
            say(.failed("the microphone could not start")); return
        }
        let input = started.name
        Log.info("draft", ["speech": "audio", "input": input ?? "unknown",
                           "hz": Int(started.format.sampleRate),
                           "channels": Int(started.format.channelCount)])
        guard !stopped else { microphone.stop(); return }
        say(.listening(input: input))
    }

    /// The microphone starts on its own queue. The ask passes through
    /// the main thread only to check the session is still the wanted
    /// one — a draft closed during prepare must not start the mic — and
    /// because `stop` is queued from main too, a session superseded
    /// after that check still has its start queued ahead of the
    /// successor's stop, which then takes the tap off again.
    private static func startMicrophone(_ microphone: AudioInput, device: String?,
                                        stillWanted: @escaping @MainActor () -> Bool,
                                        sink: @escaping (AVAudioPCMBuffer) -> Void) async throws
        -> (format: AVAudioFormat, name: String?) {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                guard stillWanted() else { continuation.resume(throwing: CancellationError()); return }
                microphone.start(device: device, sink: sink) { continuation.resume(with: $0) }
            }
        }
    }

    /// A file's audio, in 100ms slices at real-time pace, through the same
    /// feed the tap uses. The tap keeps running beside it; a quiet room
    /// adds nothing.
    func feed(file url: URL) async {
        guard let feed, !stopped else { return }
        guard let audio = try? AVAudioFile(forReading: url) else {
            Log.info("draft", ["speech": "audio file unreadable", "file": url.lastPathComponent])
            return
        }
        let sliceFrames = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        let wall = Date()
        var streamed: AVAudioFramePosition = 0
        Log.info("draft", ["speech": "feeding file", "file": url.lastPathComponent,
                           "seconds": Int(Double(audio.length) / audio.processingFormat.sampleRate)])
        while streamed < audio.length, !stopped {
            guard let slice = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: sliceFrames),
                  (try? audio.read(into: slice, frameCount: sliceFrames)) != nil, slice.frameLength > 0 else { break }
            streamed += AVAudioFramePosition(slice.frameLength)
            feed.push(slice)
            let audioClock = Double(streamed) / audio.processingFormat.sampleRate
            let ahead = audioClock - Date().timeIntervalSince(wall)
            if ahead > 0 { try? await Task.sleep(for: .milliseconds(Int(ahead * 1000))) }
        }
        Log.info("draft", ["speech": "file fed"])
    }

    private func noteResultsEnded(_ error: Error) {
        if !stopped { Log.info("draft", ["speech": "results ended", "error": "\(error)"]) }
    }

    func stop() async {
        stopped = true
        if let feed {
            Log.info("draft", ["speech": "audio summary", "buffers": feed.buffers,
                               "peakDb": Int(20 * log10(max(feed.peak, 1e-7)))])
        }
        continuation?.finish()
        continuation = nil
        // Let the last words settle; the probe measured ~100ms. Bounded, so
        // a wedged recognizer can never hold the paste.
        if let analyzer {
            // Let the last words settle; the probe measured ~100ms. Bounded,
            // so a wedged recognizer can never hold the paste: past the
            // deadline it is cut off, not waited for.
            let finish = Task { () -> Bool in
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            }
            let timeout = Task { () -> Bool in
                try? await Task.sleep(for: .milliseconds(700))
                return false
            }
            let finished = await Task.select(finish, timeout)
            if !finished { await analyzer.cancelAndFinishNow() }
        }
        results?.cancel()
        results = nil
        analyzer = nil
        transcriber = nil
    }
}

/// The audio tap's side: converts each buffer to the analyzer's format
/// and hands it over. Owned by the tap's thread; the actor only makes it.
@available(macOS 26, *)
private final class AudioFeed: @unchecked Sendable {
    private let outFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: (Float) -> Void
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var lastLevelAt = Date.distantPast
    /// What flowed, for the log at the end: proof the tap delivered, and
    /// how loud the loudest moment was.
    private(set) var buffers = 0
    private(set) var peak: Float = 0

    init(outFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping (Float) -> Void) {
        self.outFormat = outFormat
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        meter(buffer)
        if converter == nil || inFormat != buffer.format {
            inFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
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
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    /// RMS of the first channel, as a 0…1 level, at most ten times a
    /// second: enough for a meter, nothing for a recognizer.
    private func meter(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) > 0.1, let data = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }
        lastLevelAt = now
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        // Speech at a normal distance sits around -30 dBFS; the meter's
        // top is a raised voice, its floor silence.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 55) / 45))
        peak = max(peak, rms)
        DispatchQueue.main.async { self.onLevel(level) }
    }
}

private extension Task where Failure == Never {
    /// Whichever finishes first; the other keeps running.
    static func select(_ a: Task<Success, Never>, _ b: Task<Success, Never>) async -> Success {
        await withTaskGroup(of: Success.self) { group in
            group.addTask { await a.value }
            group.addTask { await b.value }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}
