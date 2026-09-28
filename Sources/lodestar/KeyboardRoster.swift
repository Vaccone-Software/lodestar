import CryptoKit
import Foundation
import IOKit.hid

/// The input devices attached right now, by identity and transport.
///
/// Hold time is a mechanical quantity: every keyboard has its own
/// switches, travel and scan rate, and a Bluetooth link quantizes every
/// stamp to its connection interval. A reach is the same story on the
/// other hand — a trackpad and a mouse are different wrist acts. A
/// change of device is a step in the measurement that has nothing to do
/// with the hand, so each window records which devices were present.
/// The HID manager is asked for its device list and never opened —
/// opening it is what asks the person for Input Monitoring, and
/// enumeration needs no such thing.
///
/// A laptop always has its own keyboard and trackpad attached, so most
/// windows on a laptop name two of each; `attribute` says which one a
/// press or a click can honestly be charged to, and says nothing when
/// it cannot. A key press names its keyboard itself: the event's
/// keyboard type is the `HIDSubinterfaceID` of the device that sent it
/// (91 on the built-in here, 40 on a Bluetooth board), and that beats
/// anything the lid can say.
class DeviceRoster {
    struct Device: Equatable {
        /// `vendor:product:hash`, the hash from the serial when there is
        /// one and the location otherwise — stable across boots, and not
        /// the serial itself.
        let id: String
        let name: String
        let transport: String
        let builtIn: Bool
        /// The type its key events carry, when the registry says; nil
        /// when it does not. Only a keyboard's is ever read.
        var keyboardType: Int? = nil
    }

    static let cacheSeconds: TimeInterval = 30

    private let matching: CFArray
    private let foreign: Set<Int>
    private var cached: [Device] = []
    private var cachedAt = Date.distantPast
    private let lock = NSLock()

    /// `foreign`: the primary usages of devices that match `usages`
    /// only by a secondary interface and are some other kind of thing.
    /// A split keyboard carries a mouse interface for its mouse keys, a
    /// mouse a keyboard one for its buttons, and neither makes it the
    /// other; counted, the Adv360 was a second mouse beside the real
    /// one and every click beside them went unattributed.
    init(usages: [Int], foreign: [Int]) {
        matching = usages.map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        } as CFArray
        self.foreign = Set(foreign)
    }

    /// Whether a device whose primary usage is `page`:`usage` belongs on
    /// a list that leaves out `foreign` generic-desktop usages.
    static func kept(page: Int?, usage: Int?, foreign: Set<Int>) -> Bool {
        guard page == kHIDPage_GenericDesktop, let usage else { return true }
        return !foreign.contains(usage)
    }

    /// The devices present, refreshed at most every half minute. One
    /// entry per physical device: a built-in keyboard and trackpad
    /// expose several HID interfaces under one identity.
    func current(now: Date = Date()) -> [Device] {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(cachedAt) < Self.cacheSeconds { return cached }
        return reload(now: now)
    }

    /// Ask the system again now, whatever the cache says.
    ///
    /// The half-minute is for the tap's path, where the list is wanted on
    /// every press and a device arriving a moment late costs nothing — a
    /// press is charged to the keyboard that was there, and one keyboard
    /// more or less does not change which. A surface showing that list to
    /// a person is the other case: a keyboard just plugged in has to be
    /// on it, and half a minute is not "just".
    func refresh(now: Date = Date()) -> [Device] {
        lock.lock()
        defer { lock.unlock() }
        return reload(now: now)
    }

    /// The registry read itself. The lock is held.
    ///
    /// A manager enumerates once, when its matching is set, and hears of
    /// arrivals and departures only when scheduled on a run loop. This
    /// one is never scheduled (scheduling is for a manager that opens
    /// devices), so a kept manager answers with the devices of the
    /// moment it was made: a Bluetooth board that reconnected after
    /// launch never appeared and one that left never went. A fresh
    /// manager per read costs a few milliseconds a half minute.
    private func reload(now: Date) -> [Device] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)
        let devices = ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).filter {
            Self.kept(page: IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsagePageKey as CFString) as? Int,
                      usage: IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? Int,
                      foreign: foreign)
        }
        var seen: Set<String> = []
        // An interface that names a keyboard type is the one to keep.
        cached = devices.map(Self.describe)
            .sorted { ($0.id, $0.keyboardType == nil ? 1 : 0) < ($1.id, $1.keyboardType == nil ? 1 : 0) }
            .filter { seen.insert($0.id).inserted }
        cachedAt = now
        return cached
    }

    var ids: [String] { current().map { $0.id } }

    /// The one-based index, in `devices`, of the device an act is
    /// charged to; zero when two could have made it.
    ///
    /// A key press's own type decides first. The devices carrying that
    /// type are the candidates, and one candidate is the keyboard. When
    /// the type is known on the list and no device carries it, the
    /// keyboard is one the list does not show (some Bluetooth boards
    /// never enumerate), and the press is charged to nobody rather than
    /// to the only keyboard that did. Without a type to go on: a single
    /// device is itself, and with the lid closed the built-in one cannot
    /// have been the one, so a single external is it. A caller that
    /// knows the act was the built-in's — a trackpad's pressure stage —
    /// or knows it was not says so with `builtIn`.
    static func attribute(_ devices: [Device], lidClosed: Bool?, builtIn: Bool? = nil,
                          keyboardType: Int = 0) -> Int {
        let typed = devices.contains { $0.keyboardType != nil }
        if keyboardType != 0, typed {
            var candidates = devices.enumerated().filter { $0.element.keyboardType == keyboardType }
            if candidates.count > 1, lidClosed == true {
                candidates = candidates.filter { !$0.element.builtIn }
            }
            return candidates.count == 1 ? candidates[0].offset + 1 : 0
        }
        if devices.count == 1 { return 1 }
        let wantExternal = builtIn == false || (builtIn == nil && lidClosed == true)
        if builtIn == true {
            let builtIns = devices.enumerated().filter { $0.element.builtIn }
            return builtIns.count == 1 ? builtIns[0].offset + 1 : 0
        }
        if wantExternal {
            let external = devices.enumerated().filter { !$0.element.builtIn }
            return external.count == 1 ? external[0].offset + 1 : 0
        }
        return 0
    }

    static func describe(_ device: IOHIDDevice) -> Device {
        func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let vendor = property(kIOHIDVendorIDKey) as? Int ?? 0
        let product = property(kIOHIDProductIDKey) as? Int ?? 0
        let serial = property(kIOHIDSerialNumberKey) as? String
        let location = property(kIOHIDLocationIDKey) as? Int
        let seed = serial ?? location.map { "loc:\($0)" } ?? "none"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return Device(
            id: "\(vendor):\(product):\(hash)",
            name: property(kIOHIDProductKey) as? String ?? "device",
            transport: property(kIOHIDTransportKey) as? String ?? "unknown",
            builtIn: (property(kIOHIDBuiltInKey) as? Bool) ?? ((property(kIOHIDBuiltInKey) as? Int) == 1),
            keyboardType: subinterface(of: device))
    }

    /// The keyboard type the device's key events will carry. It lives on
    /// the event service below the device, not on the device, and is read
    /// from the registry without opening anything.
    static func subinterface(of device: IOHIDDevice) -> Int? {
        let found = IORegistryEntrySearchCFProperty(
            IOHIDDeviceGetService(device), kIOServicePlane, "HIDEventServiceProperties" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
        return ((found as? [String: Any])?["HIDSubinterfaceID"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// The keyboards attached.
final class KeyboardRoster: DeviceRoster {
    init() { super.init(usages: [kHIDUsage_GD_Keyboard], foreign: [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer]) }
}

/// The pointing devices attached: mice, trackpads, trackballs.
final class PointerRoster: DeviceRoster {
    init() {
        super.init(usages: [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer],
                   foreign: [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad])
    }
}
