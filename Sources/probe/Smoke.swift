import CoreGraphics
import Foundation

/// The hand's acts, posted where nothing answers them, timed through the
/// real taps of whatever Lodestar is running.
///
/// A pointer move to where the pointer already is, a scroll of nothing, a
/// press of mouse button 20 (no app acts on it), and F20, a key almost
/// nothing binds. Each passes through Lodestar's key and mouse taps on its
/// way to a listening tap appended after them, which times it. A frozen or
/// wedged tap shows as events that never arrive, or arrive late. Posted
/// events carry this process's pid, so Lodestar counts none of them as a
/// hand: the health instrument's per-press path is not exercised here.
func runSmoke(_ args: inout [String]) {
    var seconds = 6.0
    var ceilingMs = 250.0
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--seconds": i += 1; seconds = Double(args[i]) ?? seconds
        case "--ceiling-ms": i += 1; ceilingMs = Double(args[i]) ?? ceilingMs
        default: break
        }
        i += 1
    }

    final class Meter: @unchecked Sendable {
        let lock = NSLock()
        var posted: [Int64: (UInt64, String)] = [:]
        var seen: [String: [Double]] = [:]
        var sent: [String: Int] = [:]
    }
    let meter = Meter()
    let tag: Int64 = 0x5A0_000
    let types: [CGEventType] = [.mouseMoved, .scrollWheel, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, _, event, info in
        let meter = Unmanaged<Meter>.fromOpaque(info!).takeUnretainedValue()
        let mark = event.getIntegerValueField(.eventSourceUserData)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        meter.lock.lock()
        if let (at, kind) = meter.posted.removeValue(forKey: mark) {
            meter.seen[kind, default: []].append(Double(now - at) / 1e6)
        }
        meter.lock.unlock()
        return Unmanaged.passUnretained(event)
    }, userInfo: Unmanaged.passUnretained(meter).toOpaque()) else {
        print("smoke: ✕ could not install a listening tap (is this terminal trusted for accessibility?)")
        exit(2)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    var serial: Int64 = 0
    func post(_ event: CGEvent, _ kind: String) {
        serial += 1
        event.setIntegerValueField(.eventSourceUserData, value: tag + serial)
        event.flags = []
        meter.lock.withLock {
            meter.posted[tag + serial] = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW), kind)
            meter.sent[kind, default: 0] += 1
        }
        event.post(tap: .cghidEventTap)
    }
    let f20: CGKeyCode = 0x5A
    let end = Date().addingTimeInterval(seconds)
    var round = 0
    while Date() < end {
        let here = CGEvent(source: nil)?.location ?? .zero
        switch round % 4 {
        case 0:
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left) { post(e, "move") }
        case 1:
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) { post(e, "scroll") }
        case 2:
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: here, mouseButton: .center) {
                    e.setIntegerValueField(.mouseEventButtonNumber, value: 20)
                    post(e, "click")
                }
            }
        default:
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: nil, virtualKey: f20, keyDown: down) { post(e, "key") }
            }
        }
        round += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    let (seen, sent, lost) = meter.lock.withLock { (meter.seen, meter.sent, meter.posted.count) }
    if lost > 0 {
        // When the lost ones were posted, from the start: a stretch says a
        // tap was down for it, a scatter says events are being dropped.
        let first = meter.lock.withLock { meter.posted.values.map(\.0).min() ?? 0 }
        let offsets = meter.lock.withLock { meter.posted.values.map { Double($0.0 - first) / 1e9 } }.sorted()
        print(String(format: "smoke: lost events posted between +%.2fs and +%.2fs of the first lost",
                     offsets.first ?? 0, offsets.last ?? 0))
    }
    var failed = lost > 0
    for kind in ["move", "scroll", "click", "key"] {
        let v = (seen[kind] ?? []).sorted()
        let posted = sent[kind] ?? 0
        guard !v.isEmpty else { print("smoke: ✕ \(kind): none of \(posted) arrived"); failed = true; continue }
        let p99 = v[min(v.count - 1, Int(Double(v.count) * 0.99))]
        let ok = p99 <= ceilingMs && v.count == posted
        if !ok { failed = true }
        print(String(format: "smoke: %@ %@ %d of %d arrived p50=%.1fms p99=%.1fms max=%.1fms",
                     ok ? "✓" : "✕", kind, v.count, posted, v[v.count / 2], p99, v.last!))
    }
    print(lost == 0 ? "smoke: ✓ none lost" : "smoke: ✕ \(lost) never arrived")
    exit(failed ? 1 : 0)
}
