import AppKit
import CoreGraphics
import Foundation

/// Which device made a pointer event, read off the event itself — the
/// question the health instrument's pointer attribution waits on. Today it
/// guesses from which devices are connected, and with a mouse and the
/// trackpad both present, a trackpad reach is charged to the mouse.
///
/// Listens for N seconds and summarizes every pointer event by its type and
/// the fields that could name a device: the mouse subtype (tablet, touch),
/// AppKit's subtype, and for the wheel whether it is continuous and whether
/// it has phases (a trackpad's and a Magic Mouse's do; a notched wheel's do
/// not). Use one device, then the other, and compare. Reads only.
func runPointer(_ args: inout [String]) {
    var seconds = 20.0
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count { seconds = Double(args[i + 1]) ?? seconds }
    final class Tally: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
    }
    let tally = Tally()
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, type, event, info in
        let tally = Unmanaged<Tally>.fromOpaque(info!).takeUnretainedValue()
        let name: String
        switch type {
        case .mouseMoved: name = "move"
        case .leftMouseDown: name = "click"
        case .rightMouseDown: name = "right-click"
        case .leftMouseDragged: name = "drag"
        case .scrollWheel: name = "scroll"
        default: name = "\(type.rawValue)"
        }
        let subtype = event.getIntegerValueField(.mouseEventSubtype)
        let appkit = NSEvent(cgEvent: event).map { "\($0.subtype.rawValue)" } ?? "-"
        var key = "\(name) subtype=\(subtype) appkit=\(appkit)"
        if type == .scrollWheel {
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            key += " continuous=\(continuous) phased=\(phase != 0 || momentum != 0)"
        }
        tally.lock.withLock { tally.counts[key, default: 0] += 1 }
        return Unmanaged.passUnretained(event)
    }, userInfo: Unmanaged.passUnretained(tally).toOpaque()) else {
        fail("could not install a listening tap (is this terminal trusted?)")
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("probe pointer: listening \(Int(seconds)) s — use one device, then the other")
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    for (key, count) in tally.lock.withLock({ tally.counts }).sorted(by: { $0.key < $1.key }) {
        print(String(format: "%6d  %@", count, key))
    }
}
