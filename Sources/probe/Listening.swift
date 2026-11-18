import AppKit
import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// `probe listening` — the questions headphone safety depends on, asked
/// before any of it is built (reports/Headphone safety plan 2026-11-18.md):
///
///   devices  every output: transport, terminal type, volume elements and
///            the scalar-to-dB curve (reads only)
///   tap      a private, unmuted global process tap: does it hear what
///            plays, at the level it was played (`--noise D` plays pink
///            noise at D dBFS from this process), is it ahead of the device
///            volume (`--nudge` lowers the volume one step halfway through
///            and puts it back, timing the property's answer), and what
///            does the IO callback cost
///   clamp    a ceiling held by a property listener against the volume-up
///            key pressed N times: how far the volume gets before the
///            listener brings it back, and whether it stays there
///   drift    the backstop against raises that are not the key: something
///            sets the volume over the ceiling, the listener puts it back,
///            and then do the keys step from the ceiling or from the raise?
///            Once outside a key session and once inside one. `--watch N`
///            instead holds the current volume as the ceiling for N seconds
///            while a person moves the slider or presses the headset's own
///            buttons, then asks the keys the same question
///
/// Everything it changes it puts back when it ends: the volume, the tap and
/// its aggregate device (an interrupted run leaves the volume where it was
/// nudged; the tap and aggregate die with the process).
func runListening(_ args: inout [String]) {
    guard !args.isEmpty else { listeningUsage() }
    let sub = args.removeFirst()
    switch sub {
    case "devices": ListeningProbe.devices()
    case "tap":
        let seconds = Double(value(of: "--seconds", in: &args) ?? "") ?? 10
        let noise = value(of: "--noise", in: &args).flatMap(Double.init)
        let nudge = has("--nudge", in: &args)
        let lean = has("--lean", in: &args)
        let frames = value(of: "--buffer", in: &args).flatMap(UInt32.init)
        let onDevice = has("--device", in: &args)
        let mono = has("--mono", in: &args)
        ListeningProbe.tap(seconds: seconds, noiseDBFS: noise, nudge: nudge, lean: lean, bufferFrames: frames,
                           onDevice: onDevice, mono: mono)
    case "drift":
        ListeningProbe.drift(watch: value(of: "--watch", in: &args).flatMap(Double.init))
    case "clamp":
        let presses = Int(value(of: "--presses", in: &args) ?? "") ?? 5
        let mode = has("--swallow", in: &args) ? ListeningProbe.ClampMode.swallow : .scalar
        ListeningProbe.clamp(presses: presses, mode: mode)
    default: listeningUsage()
    }
}

private func listeningUsage() -> Never {
    print("""
    usage:
      probe listening devices
      probe listening tap [--seconds N] [--noise DBFS] [--nudge] [--lean] [--buffer FRAMES]
                                [--device | --mono]
      probe listening clamp [--presses N] [--swallow]
      probe listening drift [--watch SECONDS]
    """)
    exit(2)
}

enum ListeningProbe {
    // MARK: CoreAudio reads

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let output = kAudioDevicePropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return "-" }
        return value.takeRetainedValue() as String
    }

    static func fourCC(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }, encoding: .ascii) ?? "\(value)"
    }

    static func defaultOutput() -> AudioObjectID {
        read(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
    }

    static func outputDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        return ids.filter { id in
            var streams = Self.address(kAudioDevicePropertyStreams, output)
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize)
            return streamSize > 0
        }
    }

    /// The elements that carry an output volume: main where the device has
    /// one, else its channels (Bluetooth has 1 and 2 and no main).
    static func volumeElements(_ id: AudioObjectID) -> [UInt32] {
        [0, 1, 2].filter { element in
            var address = address(kAudioDevicePropertyVolumeScalar, output, element)
            return AudioObjectHasProperty(id, &address)
        }
    }

    static func scalar(_ id: AudioObjectID, _ element: UInt32) -> Float32? {
        read(id, address(kAudioDevicePropertyVolumeScalar, output, element), Float32(0))
    }

    @discardableResult
    static func setScalar(_ id: AudioObjectID, _ element: UInt32, _ value: Float32) -> OSStatus {
        var address = address(kAudioDevicePropertyVolumeScalar, output, element)
        var value = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// The device's own translation, not `kAudioDevicePropertyVolumeDecibels`,
    /// which read −75 on a Bluetooth headset whose range is −40…0.
    static func decibels(_ id: AudioObjectID, _ element: UInt32, scalar: Float32) -> Float32? {
        read(id, address(kAudioDevicePropertyVolumeScalarToDecibels, output, element), scalar)
    }

    // MARK: devices

    static func devices() {
        let current = defaultOutput()
        for id in outputDevices() {
            let transport = read(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            let source = read(id, address(kAudioDevicePropertyDataSource, output), UInt32(0))
            print("\(id == current ? "* " : "  ")\(string(id, kAudioObjectPropertyName))")
            // The output stream's terminal type says headphones ('hdph') with
            // no Bluetooth permission; the Bluetooth class of device needs
            // one (CBManager.authorization was notDetermined on 2026-11-18).
            let stream = read(id, address(kAudioDevicePropertyStreams, output), AudioObjectID(0))
            let terminal = stream.flatMap { read($0, address(kAudioStreamPropertyTerminalType), UInt32(0)) }
            print("    transport \(fourCC(transport))  data source \(source.map(fourCC) ?? "-")  terminal \(terminal.map { $0 < 0x10000 ? String(format: "0x%x", $0) : fourCC($0) } ?? "-")  uid \(string(id, kAudioDevicePropertyDeviceUID))")
            for element in volumeElements(id) {
                let now = scalar(id, element) ?? -1
                let curve = stride(from: Float32(0), through: 1, by: 0.25)
                    .map { s in decibels(id, element, scalar: s).map { String(format: "%.1f", $0) } ?? "?" }
                    .joined(separator: " ")
                print(String(format: "    element %u  scalar %.3f = %@ dB   curve 0,¼,½,¾,1: %@", element, now,
                             decibels(id, element, scalar: now).map { String(format: "%.1f", $0) } ?? "?", curve))
            }
        }
    }

    // MARK: tap

    /// One 125 ms block's energy, raw and A-weighted, summed on the IO thread.
    struct Block { var frames = 0; var raw = 0.0; var weighted = 0.0; var callbacks = 0; var busy: UInt64 = 0 }

    /// What the IO thread owns: the filter's memory and the block it fills.
    /// The main thread only swaps the block out once a second.
    struct IOState {
        var weighting: AWeighting
        var block = Block()
        /// The lean path: one vDSP biquad cascade, a delay line per channel.
        var setup: vDSP_biquad_Setup?
        var delays: [[Float]] = []
        var scratch: [Float] = []
    }

    static func tap(seconds: Double, noiseDBFS: Double?, nudge: Bool, lean: Bool, bufferFrames: UInt32?,
                    onDevice: Bool, mono: Bool) {
        // Global stereo mixdown by default; --device taps the default output's
        // own stream at its own rate, --mono a mono mixdown.
        let description = onDevice
            ? CATapDescription(excludingProcesses: [], deviceUID: string(defaultOutput(), kAudioDevicePropertyDeviceUID), stream: 0)
            : mono ? CATapDescription(monoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "lodestar listening probe"
        var tapID = AudioObjectID(0)
        let created = AudioHardwareCreateProcessTap(description, &tapID)
        guard created == noErr else { print("tap: create failed \(created) (\(fourCC(UInt32(bitPattern: created))))"); exit(1) }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        guard let format = read(tapID, address(kAudioTapPropertyFormat), AudioStreamBasicDescription()) else {
            print("tap: no format"); exit(1)
        }
        print(String(format: "tap %u: %.0f Hz, %u ch, flags %x, %u bits", tapID, format.mSampleRate,
                     format.mChannelsPerFrame, format.mFormatFlags, format.mBitsPerChannel))

        let aggregateUID = UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "lodestar listening probe",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(0)
        let made = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard made == noErr else { print("tap: aggregate failed \(made)"); exit(1) }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        let rate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var initial = IOState(weighting: AWeighting(sampleRate: rate, channels: channels))
        if lean {
            let coefficients = initial.weighting.biquadCoefficients
            initial.setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(coefficients.count / 5))
            initial.delays = Array(repeating: Array(repeating: 0, count: 2 * coefficients.count / 5 + 2), count: channels)
            initial.scratch = Array(repeating: 0, count: 16384)
        }
        let io = Mutex(initial)
        if let bufferFrames {
            let range = read(aggregate, address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange())
            var frames = bufferFrames
            var sizeAddress = address(kAudioDevicePropertyBufferFrameSize)
            let set = AudioObjectSetPropertyData(aggregate, &sizeAddress, 0, nil, 4, &frames)
            let now = read(aggregate, address(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? 0
            print("buffer: asked \(bufferFrames) frames, status \(set), now \(now), range \(range.map { "\($0.mMinimum)…\($0.mMaximum)" } ?? "-")")
        }
        let timebase = ListeningProbe.timebase

        var procID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "listening.io", qos: .userInteractive)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, _, _, _ in
            let start = mach_absolute_time()
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            io.withLock { state in
            if lean, let setup = state.setup {
                var raw = 0.0, weighted = 0.0, frames = 0
                for buffer in list {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                    let stride = Int(buffer.mNumberChannels)
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / max(stride, 1)
                    let n = min(count, state.scratch.count)
                    for channel in 0..<min(stride, state.delays.count) {
                        var energy: Float = 0
                        vDSP_svesq(data + channel, vDSP_Stride(stride), &energy, vDSP_Length(n))
                        raw += Double(energy)
                        state.scratch.withUnsafeMutableBufferPointer { out in
                            state.delays[channel].withUnsafeMutableBufferPointer { delay in
                                vDSP_biquad(setup, delay.baseAddress!, data + channel, vDSP_Stride(stride),
                                            out.baseAddress!, 1, vDSP_Length(n))
                                vDSP_svesq(out.baseAddress!, 1, &energy, vDSP_Length(n))
                            }
                        }
                        weighted += Double(energy)
                    }
                    frames = n
                }
                state.block.raw += raw; state.block.weighted += weighted; state.block.frames += frames
                state.block.callbacks += 1; state.block.busy += mach_absolute_time() - start
                return
            }
            var raw = 0.0, weighted = 0.0, frames = 0
            for (index, buffer) in list.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let stride = interleaved ? Int(buffer.mNumberChannels) : 1
                for sample in 0..<count {
                    let channel = interleaved ? sample % stride : index
                    let x = Double(data[sample])
                    raw += x * x
                    let y = state.weighting.process(x, channel: channel)
                    weighted += y * y
                }
                frames = interleaved ? count / max(stride, 1) : count
            }
            state.block.raw += raw; state.block.weighted += weighted; state.block.frames += frames
            state.block.callbacks += 1; state.block.busy += mach_absolute_time() - start
            }
        }
        guard status == noErr, let procID else { print("tap: IOProc failed \(status)"); exit(1) }
        defer { AudioDeviceDestroyIOProcID(aggregate, procID) }

        let player: NoisePlayer?
        do { player = try noiseDBFS.map { try NoisePlayer(dBFS: $0) } } catch {
            fputs("tap: could not make the noise: \(error)\n", stderr)
            exit(1)
        }
        let device = defaultOutput()
        let elements = volumeElements(device)
        let original = elements.map { scalar(device, $0) ?? 0 }
        let restore = { for (element, value) in zip(elements, original) { setScalar(device, element, value) } }
        defer { restore() }

        let volumeDB = { () -> Double in
            guard let element = elements.first, let now = scalar(device, element) else { return 0 }
            return Double(decibels(device, element, scalar: now) ?? 0)
        }
        print("output: \(string(device, kAudioObjectPropertyName)), volume \(String(format: "%.1f", volumeDB())) dB on elements \(elements)")
        if let noiseDBFS { print(String(format: "playing pink noise at %.1f dBFS (rms, unweighted)", noiseDBFS)) }

        // The volume property's answer to a set, timed by its own listener.
        let answered = Mutex<[Double]>([])
        let setTime = Mutex<UInt64>(0)
        if nudge, let element = elements.first {
            var address = address(kAudioDevicePropertyVolumeScalar, output, element)
            AudioObjectAddPropertyListenerBlock(device, &address, queue) { _, _ in
                let sent = setTime.withLock { $0 }
                guard sent > 0 else { return }
                let ms = Double((mach_absolute_time() - sent) * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1e6
                answered.withLock { $0.append(ms) }
            }
        }

        let running = read(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0))
        print("output running somewhere: \(running.map(String.init) ?? "-")")
        let cpuBefore = ListeningProbe.processCPU()
        player?.start()
        let started = AudioDeviceStart(aggregate, procID)
        guard started == noErr else { print("tap: start failed \(started)"); exit(1) }
        let clock = ContinuousClock()
        let begin = clock.now
        var seconds_ = 0
        var nudged = false
        var levels: [(t: Int, raw: Double, a: Double, vol: Double)] = []
        while clock.now - begin < .seconds(seconds) {
            Thread.sleep(forTimeInterval: 1)
            seconds_ += 1
            if nudge, !nudged, Double(seconds_) >= seconds / 2 {
                nudged = true
                setTime.withLock { $0 = mach_absolute_time() }
                for (element, value) in zip(elements, original) { setScalar(device, element, max(0, value - 0.0625)) }
                print("  -- volume lowered one step (2.5 dB on Bluetooth) --")
            }
            let block = io.withLock { state -> Block in let copy = state.block; state.block = Block(); return copy }
            let n = Double(max(block.frames * channels, 1))
            let raw = 10 * log10(max(block.raw / n, 1e-12))
            let a = 10 * log10(max(block.weighted / n, 1e-12))
            let busyMS = Double(block.busy * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1e6
            let vol = volumeDB()
            levels.append((seconds_, raw, a, vol))
            print(String(format: "  %3ds  raw %6.1f dBFS  A %6.1f dBFS(A)  volume %5.1f dB  at the ear if 110: %5.1f dBA  callbacks %3d  io %.2f ms",
                         seconds_, raw, a, vol, 110 + a + vol, block.callbacks, busyMS))
        }
        AudioDeviceStop(aggregate, procID)
        let cpu = ListeningProbe.processCPU() - cpuBefore
        player?.stop()
        print(String(format: "result: the whole process used %.1f ms of CPU per second (%.2f%% of a core)%@",
                     cpu * 1000 / seconds, cpu * 100 / seconds, noiseDBFS == nil ? "" : ", the noise player included"))
        restore()

        let silent = levels.allSatisfy { $0.raw < -110 }
        if silent {
            print("result: the tap heard only zeros. Either nothing played, or System Audio Recording is not granted to the app this ran from.")
        }
        if let noiseDBFS, !silent {
            let mean = levels.dropFirst().map(\.raw).reduce(0, +) / Double(max(levels.count - 1, 1))
            print(String(format: "result: played %.1f dBFS, heard %.1f dBFS (difference %+.1f dB)", noiseDBFS, mean, mean - noiseDBFS))
        }
        if nudge {
            let half = Int(seconds / 2)
            let before = levels.filter { $0.t < half && $0.t > 1 }.map(\.raw)
            let after = levels.filter { $0.t > half + 1 }.map(\.raw)
            if !before.isEmpty, !after.isEmpty {
                let b = before.reduce(0, +) / Double(before.count), a = after.reduce(0, +) / Double(after.count)
                print(String(format: "result: tap level before the nudge %.1f, after %.1f (change %+.1f dB; ~0 means the tap is ahead of the device volume)", b, a, a - b))
            }
            let times = answered.withLock { $0 }
            print("result: volume property answered the set after \(times.map { String(format: "%.1f ms", $0) }.joined(separator: ", "))")
        }
    }

    // MARK: clamp

    /// How the ceiling is held: the per-channel scalars put back after the
    /// system raises them, or the volume-up key swallowed by an event tap
    /// before the system sees it, with the scalar listener still behind it.
    /// (Putting back the virtual main volume instead was measured on
    /// 2026-11-18 and climbed the same way, +10 dB in four presses.)
    enum ClampMode: String { case scalar, swallow }

    static func pressVolumeUp() { pressVolume(soundUp) }

    static func pressVolume(_ key: Int) {
        for state in [0xa, 0xb] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: (key << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static let soundUp = 0 // NX_KEYTYPE_SOUND_UP
    static let soundDown = 1 // NX_KEYTYPE_SOUND_DOWN

    /// User and system CPU seconds this process has used.
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    static func clamp(presses: Int, mode: ClampMode) {
        let device = defaultOutput()
        let elements = volumeElements(device)
        guard !elements.isEmpty else { print("clamp: the default output has no settable volume"); exit(1) }
        let original = elements.map { scalar(device, $0) ?? 0 }
        let ceiling = original.max() ?? 0
        let restore = { for (element, value) in zip(elements, original) { setScalar(device, element, value) } }
        defer { restore() }

        let timebase = ListeningProbe.timebase
        let begin = mach_absolute_time()
        let ms: @Sendable () -> Double = { Double((mach_absolute_time() - begin) * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1e6 }
        let log = Mutex<[String]>([])
        let peak = Mutex<Float32>(ceiling)
        let clamps = Mutex(0)
        let armed = Mutex(true)
        let queue = DispatchQueue(label: "listening.clamp", qos: .userInteractive)
        for element in elements {
            var address = address(kAudioDevicePropertyVolumeScalar, output, element)
            AudioObjectAddPropertyListenerBlock(device, &address, queue) { _, _ in
                guard let now = scalar(device, element) else { return }
                guard armed.withLock({ $0 }) else {
                    log.withLock { $0.append(String(format: "  %7.1f ms  element %u at %.3f (unclamped)", ms(), element, now)) }
                    return
                }
                peak.withLock { $0 = max($0, now) }
                if now > ceiling + 0.0005 {
                    setScalar(device, element, ceiling)
                    clamps.withLock { $0 += 1 }
                    log.withLock { $0.append(String(format: "  %7.1f ms  element %u rose to %.3f, held at %.3f", ms(), element, now, ceiling)) }
                } else {
                    log.withLock { $0.append(String(format: "  %7.1f ms  element %u at %.3f", ms(), element, now)) }
                }
            }
        }

        if mode == .swallow {
            let first = elements[0]
            let started = SwallowTap.start(
                atCeiling: { (scalar(device, first) ?? 0) >= ceiling - 0.0005 },
                note: { line in log.withLock { $0.append(String(format: "  %7.1f ms  %@", ms(), line)) } })
            guard started else { print("clamp: could not create the event tap (Accessibility?)"); exit(1) }
        }

        print(String(format: "clamp (%@): %@, ceiling = current %.3f (%@ dB), pressing volume up %d times",
                     mode.rawValue, string(device, kAudioObjectPropertyName), ceiling,
                     decibels(device, elements[0], scalar: ceiling).map { String(format: "%.1f", $0) } ?? "?", presses))
        for press in 0..<presses {
            log.withLock { $0.append(String(format: "  %7.1f ms  press %d", ms(), press + 1)) }
            pressVolumeUp()
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let top = peak.withLock { $0 }
        let settled = elements.map { scalar(device, $0) ?? -1 }

        // Where does the system's own idea of the volume stand now? One
        // more press with nothing holding the ceiling says it.
        armed.withLock { $0 = false }
        SwallowTap.stop()
        log.withLock { $0.append(String(format: "  %7.1f ms  one unclamped press", ms())) }
        pressVolumeUp()
        Thread.sleep(forTimeInterval: 0.6)
        let after = scalar(device, elements[0]) ?? -1
        restore()

        for line in log.withLock({ $0 }) { print(line) }
        let db = { (s: Float32) in Double(decibels(device, elements[0], scalar: s) ?? 0) }
        print(String(format: "result: %d clamps, highest seen %.3f (%+.1f dB over the ceiling), settled at %@",
                     clamps.withLock { $0 }, top, db(top) - db(ceiling),
                     settled.map { String(format: "%.3f", $0) }.joined(separator: "/")))
        print(String(format: "result: the next unclamped press went to %.3f (%+.1f dB over the ceiling; one step is %+.1f)",
                     after, db(after) - db(ceiling), db(min(1, ceiling + 0.0625)) - db(ceiling)))
    }
}

extension ListeningProbe {
    static let step: Float32 = 1.0 / 16 // one volume key press

    static func drift(watch: Double?) {
        let device = defaultOutput()
        let elements = volumeElements(device)
        guard let first = elements.first else { print("drift: the default output has no settable volume"); exit(1) }
        let original = elements.map { scalar(device, $0) ?? 0 }
        let ceiling = original[0]
        let restore = { for (element, value) in zip(elements, original) { setScalar(device, element, value) } }
        defer { restore() }
        let setAll = { (value: Float32) in for element in elements { setScalar(device, element, value) } }
        let now = { scalar(device, first) ?? -1 }
        let db = { (s: Float32) in Double(decibels(device, first, scalar: s) ?? 0) }
        let rel = { (s: Float32) in String(format: "%.3f (%+.1f dB from the ceiling)", s, db(s) - db(ceiling)) }

        let timebase = ListeningProbe.timebase
        let begin = mach_absolute_time()
        let ms: @Sendable () -> Double = { Double((mach_absolute_time() - begin) * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1e6 }
        let log = Mutex<[String]>([])
        let note: @Sendable (String) -> Void = { line in log.withLock { $0.append(String(format: "  %8.1f ms  %@", ms(), line)) } }
        let peak = Mutex<Float32>(ceiling)
        let armed = Mutex(true)
        let queue = DispatchQueue(label: "listening.drift", qos: .userInteractive)
        for element in elements {
            var address = address(kAudioDevicePropertyVolumeScalar, output, element)
            AudioObjectAddPropertyListenerBlock(device, &address, queue) { _, _ in
                guard let value = scalar(device, element) else { return }
                guard armed.withLock({ $0 }) else {
                    note(String(format: "element %u at %.3f (unheld)", element, value))
                    return
                }
                peak.withLock { $0 = max($0, value) }
                if value > ceiling + 0.0005 {
                    setScalar(device, element, ceiling)
                    note(String(format: "element %u rose to %.3f, backstop put it at %.3f", element, value, ceiling))
                } else {
                    note(String(format: "element %u at %.3f", element, value))
                }
            }
        }
        guard SwallowTap.start(atCeiling: { (scalar(device, first) ?? 0) >= ceiling - 0.0005 }, note: note) else {
            print("drift: could not create the event tap (Accessibility?)"); exit(1)
        }
        defer { SwallowTap.stop() }

        print("drift: \(string(device, kAudioObjectPropertyName)), ceiling = current \(rel(ceiling)), one key step = \(String(format: "%.1f", db(min(1, ceiling + step)) - db(ceiling))) dB")
        var results: [String] = []
        func press(_ key: Int, _ label: String) {
            note("press \(label)")
            pressVolume(key)
            Thread.sleep(forTimeInterval: 0.6)
            results.append("\(label) went to \(rel(now()))")
        }

        if let watch {
            print("drift: watching for \(Int(watch)) s. Raise the volume with the slider, then with the headset's own button")
            Thread.sleep(forTimeInterval: watch)
            results.append("after watching, settled at \(rel(now())), highest seen \(rel(peak.withLock { $0 }))")
            Thread.sleep(forTimeInterval: 1)
            press(soundDown, "volume down")
            Thread.sleep(forTimeInterval: 4)
            press(soundUp, "volume up")
        } else {
            // Outside a key session: no key for four seconds before the raise.
            Thread.sleep(forTimeInterval: 4)
            note("app raise to ceiling + 2 steps")
            setAll(min(1, ceiling + 2 * step))
            Thread.sleep(forTimeInterval: 1)
            results.append("outside a session: app raise settled at \(rel(now()))")
            press(soundDown, "outside a session: volume down")
            Thread.sleep(forTimeInterval: 4)
            press(soundUp, "outside a session: volume up")

            // Inside a key session: the raise lands between two presses.
            Thread.sleep(forTimeInterval: 4)
            press(soundDown, "inside a session: volume down")
            note("app raise to ceiling + 2 steps")
            setAll(min(1, ceiling + 2 * step))
            Thread.sleep(forTimeInterval: 0.4)
            results.append("inside a session: app raise settled at \(rel(now()))")
            press(soundDown, "inside a session: volume down again")
            press(soundUp, "inside a session: volume up")
            press(soundUp, "inside a session: volume up at the ceiling")
        }
        SwallowTap.stop()
        restore()
        // Where the keys' own count stands after it is all put back: one
        // press down and one up, outside a session, with nothing holding.
        Thread.sleep(forTimeInterval: 4)
        armed.withLock { $0 = false }
        note("count check: volume down")
        pressVolume(soundDown)
        Thread.sleep(forTimeInterval: 0.6)
        let down = now()
        Thread.sleep(forTimeInterval: 4)
        note("count check: volume up")
        pressVolume(soundUp)
        Thread.sleep(forTimeInterval: 0.6)
        let up = now()

        for line in log.withLock({ $0 }) { print(line) }
        for line in results { print("result: \(line)") }
        print("result: highest seen \(rel(peak.withLock { $0 }))")
        print("result: count check after restoring, down went to \(rel(down)), up to \(rel(up)) (aligned = one step below, then the ceiling)")
    }
}

/// A session event tap that drops volume-up while the device is at the
/// ceiling, so the system never takes the step.
enum SwallowTap {
    private struct State {
        var atCeiling: @Sendable () -> Bool = { false }
        var note: @Sendable (String) -> Void = { _ in }
        var port: CFMachPort?
        var loop: CFRunLoop?
    }
    private static let state = Mutex(State())

    static func start(atCeiling: @escaping @Sendable () -> Bool, note: @escaping @Sendable (String) -> Void) -> Bool {
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let key = (ns.data1 & 0xFFFF0000) >> 16
            let down = (ns.data1 & 0xFF00) >> 8 == 0xa
            guard key == ListeningProbe.soundUp else { return Unmanaged.passUnretained(event) }
            let (check, note) = SwallowTap.state.withLock { ($0.atCeiling, $0.note) }
            if check() {
                note("tap swallowed volume-up (\(down ? "down" : "up"))")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        state.withLock { $0.atCeiling = atCeiling; $0.note = note; $0.port = port }
        let ready = DispatchSemaphore(value: 0)
        Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            SwallowTap.state.withLock { $0.loop = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }.start()
        ready.wait()
        return true
    }

    static func stop() {
        let (port, loop) = state.withLock { s in
            defer { s.port = nil; s.loop = nil }
            return (s.port, s.loop)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }
}

/// IEC 61672 A-weighting as six first-order sections (bilinear, prewarped),
/// normalized to 0 dB at 1 kHz. Each channel keeps its own state; it lives
/// inside the IO thread's lock.
struct AWeighting: Sendable {
    private struct Section: Sendable { var b0: Double; var b1: Double; var a1: Double }
    private let sections: [Section]
    private var x1: [[Double]]
    private var y1: [[Double]]
    private var gain = 1.0

    init(sampleRate fs: Double, channels: Int) {
        let k = 2 * fs
        func warp(_ hz: Double) -> Double { k * tan(.pi * hz / fs) }
        func highPass(_ hz: Double) -> Section { let w = warp(hz); return Section(b0: k / (k + w), b1: -k / (k + w), a1: (w - k) / (k + w)) }
        func lowPass(_ hz: Double) -> Section { let w = warp(hz); return Section(b0: w / (k + w), b1: w / (k + w), a1: (w - k) / (k + w)) }
        sections = [highPass(20.598997), highPass(20.598997), highPass(107.65265), highPass(737.86223),
                    lowPass(12194.217), lowPass(12194.217)]
        x1 = Array(repeating: Array(repeating: 0, count: 6), count: max(channels, 1))
        y1 = x1
        // |H| at 1 kHz from each section's response at z = e^{jω}.
        let omega = 2 * Double.pi * 1000 / fs
        var magnitude = 1.0
        for s in sections {
            let numRe = s.b0 + s.b1 * cos(omega), numIm = -s.b1 * sin(omega)
            let denRe = 1 + s.a1 * cos(omega), denIm = -s.a1 * sin(omega)
            magnitude *= sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
        }
        gain = 1 / magnitude
    }

    /// The same cascade as vDSP biquads (b0 b1 b2 a1 a2 per section), the
    /// 1 kHz normalization folded into the first.
    var biquadCoefficients: [Double] {
        sections.enumerated().flatMap { index, s in
            let g = index == 0 ? gain : 1
            return [s.b0 * g, s.b1 * g, 0, s.a1, 0]
        }
    }

    mutating func process(_ input: Double, channel: Int) -> Double {
        let c = min(channel, x1.count - 1)
        var x = input
        for i in 0..<sections.count {
            let s = sections[i]
            let y = s.b0 * x + s.b1 * x1[c][i] - s.a1 * y1[c][i]
            x1[c][i] = x
            y1[c][i] = y
            x = y
        }
        return x * gain
    }
}

/// Pink noise (Paul Kellet's filter) at an exact RMS, written to one
/// temporary file (the same name each run, so runs never pile up) and
/// looped through the default output.
final class NoisePlayer {
    private let player: AVAudioPlayer

    init(dBFS: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let frames = AVAudioFrameCount(48000 * 4)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var b = [Double](repeating: 0, count: 7)
        var samples = [Double](repeating: 0, count: Int(frames))
        var generator = SystemRandomNumberGenerator()
        for i in 0..<Int(frames) {
            let white = Double.random(in: -1...1, using: &generator)
            b[0] = 0.99886 * b[0] + white * 0.0555179; b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520; b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522; b[5] = -0.7616 * b[5] - white * 0.0168980
            samples[i] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
        }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        let scale = pow(10, dBFS / 20) / rms
        for channel in 0..<2 {
            let out = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { out[i] = Float(samples[i] * scale) }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lodestar-listening-noise.caf")
        try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        player = try AVAudioPlayer(contentsOf: file)
        player.numberOfLoops = -1
    }

    func start() { player.play() }

    func stop() { player.stop() }
}
