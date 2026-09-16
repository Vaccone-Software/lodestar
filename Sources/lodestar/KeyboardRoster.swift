import CryptoKit
import Foundation
import IOKit.hid

/// The keyboards attached right now, by identity and transport.
///
/// Hold time is a mechanical quantity: every keyboard has its own
/// switches, travel and scan rate, and a Bluetooth link quantizes every
/// stamp to its connection interval. A change of keyboard is a step in
/// the measurement that has nothing to do with the hand, so each window
/// records which keyboards were present. The HID manager is asked for
/// its device list and never opened — opening it is what asks the person
/// for Input Monitoring, and enumeration needs no such thing.
///
/// A laptop always has its own keyboard attached, so most windows on a
/// laptop name two; the per-press keyboard type code, kept beside, is
/// what separates them when it can.
final class KeyboardRoster {
    struct Keyboard: Equatable {
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
    private var cached: [Keyboard] = []
    private var cachedAt = Date.distantPast
    private let lock = NSLock()

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
    }

    /// The keyboards present, refreshed at most every half minute.
    func current(now: Date = Date()) -> [Keyboard] {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(cachedAt) < Self.cacheSeconds { return cached }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        cached = devices.map(Self.describe).sorted { $0.id < $1.id }
        cachedAt = now
        return cached
    }

    var ids: [String] { current().map { $0.id } }

    static func describe(_ device: IOHIDDevice) -> Keyboard {
        func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let vendor = property(kIOHIDVendorIDKey) as? Int ?? 0
        let product = property(kIOHIDProductIDKey) as? Int ?? 0
        let serial = property(kIOHIDSerialNumberKey) as? String
        let location = property(kIOHIDLocationIDKey) as? Int
        let seed = serial ?? location.map { "loc:\($0)" } ?? "none"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return Keyboard(
            id: "\(vendor):\(product):\(hash)",
            name: property(kIOHIDProductKey) as? String ?? "keyboard",
            transport: property(kIOHIDTransportKey) as? String ?? "unknown",
            builtIn: (property(kIOHIDBuiltInKey) as? Bool) ?? ((property(kIOHIDBuiltInKey) as? Int) == 1))
    }
}
