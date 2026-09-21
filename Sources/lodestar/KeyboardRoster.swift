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
/// it cannot.
class DeviceRoster {
    struct Device: Equatable {
        /// `vendor:product:hash`, the hash from the serial when there is
        /// one and the location otherwise — stable across boots, and not
        /// the serial itself.
        let id: String
        let name: String
        let transport: String
        let builtIn: Bool
    }

    static let cacheSeconds: TimeInterval = 30

    private let manager: IOHIDManager
    private var cached: [Device] = []
    private var cachedAt = Date.distantPast
    private let lock = NSLock()

    init(usages: [Int]) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = usages.map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
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
    private func reload(now: Date) -> [Device] {
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var seen: Set<String> = []
        cached = devices.map(Self.describe)
            .sorted { $0.id < $1.id }
            .filter { seen.insert($0.id).inserted }
        cachedAt = now
        return cached
    }

    var ids: [String] { current().map { $0.id } }

    /// The one-based index, in `ids`, of the device an act is charged
    /// to; zero when two could have made it. A single device is itself.
    /// With the lid closed the built-in one cannot have been the one, so
    /// a single external is it. A caller that knows the act was the
    /// built-in's — a trackpad's pressure stage — or knows it was not
    /// says so with `builtIn`.
    func attribute(lidClosed: Bool?, builtIn: Bool? = nil) -> Int {
        let devices = current()
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
            builtIn: (property(kIOHIDBuiltInKey) as? Bool) ?? ((property(kIOHIDBuiltInKey) as? Int) == 1))
    }
}

/// The keyboards attached.
final class KeyboardRoster: DeviceRoster {
    init() { super.init(usages: [kHIDUsage_GD_Keyboard]) }
}

/// The pointing devices attached: mice, trackpads, trackballs.
final class PointerRoster: DeviceRoster {
    init() { super.init(usages: [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer]) }
}
