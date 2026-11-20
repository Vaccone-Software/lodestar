import CoreAudio
import Foundation
import Stoic
import StoicTime
import Synchronization

/// `probe listening mics [--watch SECONDS]`: which apps have a microphone
/// open, by CoreAudio's process objects (macOS 14.2 and later, no
/// permission). Reduce loud audio's call allowance rests on it: a call is a
/// meeting app or a browser holding the microphone, and Lodestar's own
/// dictation is not one.
///
/// Without `--watch` it lists every audio process once. With it, it also
/// listens to the process list and to each process's input, and prints
/// every change with how long after the start it came, then, once a second,
/// what a poll sees, so a listener that never fires shows as a poll that
/// changes with no listener line before it.
extension ListeningProbe {
    struct AudioProcess: Equatable {
        var object: AudioObjectID
        var pid: Int32
        var bundle: String
        var input: Bool
        var output: Bool
    }

    static func audioProcesses() -> [AudioProcess] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioProcess(object: id,
                         pid: read(id, Self.address(kAudioProcessPropertyPID), Int32(0)) ?? 0,
                         bundle: string(id, kAudioProcessPropertyBundleID),
                         input: (read(id, Self.address(kAudioProcessPropertyIsRunningInput), UInt32(0)) ?? 0) != 0,
                         output: (read(id, Self.address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0)
        }
    }

    static func mics(watch: Double?) {
        let start = Moment.now.date
        func stamp() -> String { String(format: "%7.2fs", Moment.now.date.timeIntervalSince(start)) }
        func line(_ p: AudioProcess) -> String {
            "\(p.input ? "MIC " : "    ")\(p.output ? "OUT " : "    ")pid \(p.pid)  \(p.bundle)  (object \(p.object))"
        }
        let now = audioProcesses()
        print("\(now.count) audio processes, \(now.filter(\.input).count) with a microphone open:")
        for p in now.sorted(by: { ($0.input ? 0 : 1, $0.bundle) < ($1.input ? 0 : 1, $1.bundle) }) { print("  " + line(p)) }
        guard let watch else { return }

        let queue = DispatchQueue(label: "probe.mics")
        let watched = Mutex<Set<AudioObjectID>>([])
        func listenInput(_ id: AudioObjectID) {
            guard watched.withLock({ $0.insert(id).inserted }) else { return }
            var input = address(kAudioProcessPropertyIsRunningInput)
            let status = AudioObjectAddPropertyListenerBlock(id, &input, queue) { _, _ in
                let on = (read(id, address(kAudioProcessPropertyIsRunningInput), UInt32(0)) ?? 0) != 0
                print("\(stamp()) listener: input \(on ? "OPEN  " : "closed") \(string(id, kAudioProcessPropertyBundleID)) (object \(id))")
            }
            if status != noErr { print("\(stamp()) listener on object \(id) failed \(status)") }
        }
        now.forEach { listenInput($0.object) }
        var list = address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &list, queue) { _, _ in
            let processes = audioProcesses()
            print("\(stamp()) listener: process list now \(processes.count)")
            processes.forEach { listenInput($0.object) }
        }

        print("watching for \(Int(watch)) s: start and end a call, mute and unmute, dictate")
        var last = now.filter(\.input).map(\.bundle).sorted()
        let end = Moment.now.date.addingTimeInterval(watch)
        while Moment.now.date < end {
            RunLoop.current.run(until: Moment.now.date.addingTimeInterval(1))
            let open = audioProcesses().filter(\.input).map(\.bundle).sorted()
            if open != last {
                print("\(stamp()) poll: microphone open in \(open.isEmpty ? "nothing" : open.joined(separator: ", "))")
                last = open
            }
        }
    }
}
