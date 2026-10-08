import Foundation
import IOKit.hid
import LodestarCore

/// The keyboards' own reports, heard through the HID manager, for exact
/// attribution (`KeyReportMatcher`). Opened only with
/// `health.exact-keyboards` on and Input Monitoring granted; never seized,
/// so every other reader of the keyboards hears them as before.
///
/// The callback runs on the listener's own thread and does what the tap
/// callbacks do (`HealthMonitor`): it copies four fields off the value and
/// hands them on with `report`, which only enqueues. It never takes a lock
/// and never waits, so nothing the work behind it ever does can hold a
/// keyboard's reports up. Only keydowns on the keyboard page are passed;
/// the usage goes no further than the matcher.
final class KeyboardListener {
    /// A key went down: its usage, its stamp in monotonic nanoseconds, the
    /// device. Called on the listener's thread; must only enqueue.
    private let report: (UInt32, Double, IOHIDDevice) -> Void
    private var manager: IOHIDManager?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(report: @escaping (UInt32, Double, IOHIDDevice) -> Void) {
        self.report = report
    }

    var isListening: Bool { manager != nil }

    /// Open the manager on keyboards and keypads. False when macOS refuses
    /// (Input Monitoring not granted), and nothing is left running.
    func start() -> Bool {
        guard manager == nil else { return true }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            Log.info("health: keyboards", ["listening": false, "why": "not permitted"])
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<KeyboardListener>.fromOpaque(context).takeUnretainedValue().received(value)
        }, context)
        self.manager = manager
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let manager = self.manager else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "lodestar.keyboards"
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
        _ = ready.wait(timeout: .now() + 1)
        Log.info("health: keyboards", ["listening": true])
        return true
    }

    func stop() {
        guard let manager else { return }
        if let runLoop {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopStop(runLoop)
        }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        runLoop = nil
        thread = nil
    }

    deinit { stop() }

    /// The listener's thread.
    private func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
              IOHIDValueGetIntegerValue(value) == 1 else { return }
        let usage = IOHIDElementGetUsage(element)
        report(usage, EventTime.nanoseconds(ticks: IOHIDValueGetTimeStamp(value)), IOHIDElementGetDevice(element))
    }
}
