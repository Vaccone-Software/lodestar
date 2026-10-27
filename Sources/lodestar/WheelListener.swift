import Foundation
import IOKit.hid
import LodestarCore

/// The mice's own wheel reports, heard through the HID manager, so a scroll
/// can be told to a device (`MouseScroll`). A wheel is Generic Desktop usage
/// 0x38, and only that value is asked for: the pointer's motion, which is
/// the bulk of a mouse's traffic, never reaches the callback. Opened while a
/// wheel is ticked or the Reversed wheels page is on screen, and needs Input
/// Monitoring; never seized, so every other reader of the mouse hears it as
/// before.
///
/// The callback runs on the listener's own thread, as `KeyboardListener`'s
/// does, and hands on the device's roster id and name and the report's stamp
/// with `report`, which must stay brief: it is the one thing a scroll's
/// attribution waits on through the tap's lock, and it never waits for
/// anything itself. A device is read once, the first time it turns a wheel,
/// on this same thread, so no one else waits on the registry either. A
/// virtual device (a remapper's, `DeviceRoster.isVirtual`) is never a mouse
/// the person owns, so its reports are not passed on.
final class WheelListener {
    /// A wheel turned: the device's roster id and name, and the report's
    /// stamp in nanoseconds of uptime, the clock a tap's event is stamped
    /// on. Called on the listener's thread.
    private let report: (String, String, UInt64) -> Void
    private var manager: IOHIDManager?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Who a device is. It keeps the device itself, so that the address it
    /// is filed under is never reused.
    private struct Identity {
        let device: IOHIDDevice
        let id: String
        let name: String
        let virtual: Bool
    }
    private var identities: [UnsafeMutableRawPointer: Identity] = [:]
    private let identityLock = NSLock()

    /// Whether a manager may be opened. A test run never opens one.
    var canOpen: () -> Bool = { !TestRun.active }

    init(report: @escaping (String, String, UInt64) -> Void) {
        self.report = report
    }

    var isListening: Bool { manager != nil }

    /// Open the manager on mice and pointers. False when macOS refuses
    /// (Input Monitoring not granted), and nothing is left running.
    func start() -> Bool {
        guard manager == nil else { return true }
        guard canOpen() else { return false }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop,
                                                    kIOHIDElementUsageKey: kHIDUsage_GD_Wheel] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            Log.info("mice: wheels", ["listening": false, "why": "not permitted"])
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<WheelListener>.fromOpaque(context).takeUnretainedValue().received(value)
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
        thread.name = "lodestar.wheels"
        // A scroll is attributed on the tap's thread the moment it arrives,
        // so the report that vouches for it must already be in.
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        _ = ready.wait(timeout: .now() + 1)
        Log.info("mice: wheels", ["listening": true])
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
        identityLock.withLock { identities = [:] }
        Log.info("mice: wheels", ["listening": false])
    }

    deinit { stop() }

    /// The listener's thread. A wheel at rest reports nothing, so a zero is
    /// not a turn.
    private func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard MouseScroll.isVerticalWheel(page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element)),
              IOHIDValueGetIntegerValue(value) != 0 else { return }
        let device = IOHIDElementGetDevice(element)
        let key = Unmanaged.passUnretained(device).toOpaque()
        var known = identityLock.withLock { identities[key] }
        if known == nil {
            let described = DeviceRoster.describe(device)
            let made = Identity(device: device, id: described.id, name: described.name,
                                virtual: DeviceRoster.isVirtual(device))
            identityLock.withLock { identities[key] = made }
            known = made
        }
        guard let identity = known, !identity.virtual else { return }
        report(identity.id, identity.name, UInt64(max(0, EventTime.nanoseconds(ticks: IOHIDValueGetTimeStamp(value)))))
    }
}
