import AppKit
import Foundation
import Virtualization

// lodestar-vm: boot a macOS virtual machine from a bundle folder, with no
// third party between Lodestar and Apple's Virtualization framework.
//
// A bundle is a folder of three files, the layout Tart also uses, so a
// provisioned image from it opens here unchanged:
//
//   config.json   hardwareModel and ecid (base64 of the framework's own data
//                 representations), macAddress, cpuCount, memorySize (bytes)
//   disk.img      the raw disk
//   nvram.bin     the Mac's auxiliary storage
//
//   lodestar-vm run <bundle> [--cpus N] [--memory-gb N] [--window]
//   lodestar-vm clone <from> <to>      copy on write, with a MAC address of its own
//   lodestar-vm ip <bundle>            the address the guest leased, once it has one
//
// `run` stays in the foreground until the guest stops. SIGINT, SIGTERM,
// SIGHUP, or the process that started it going away, asks the guest to shut
// down and stops it outright thirty seconds later: a script killed outright
// never leaves a guest holding gigabytes of memory behind it.

struct Config: Codable {
    var hardwareModel: String
    var ecid: String
    var macAddress: String
    var cpuCount: Int
    var memorySize: UInt64
    var display: Display?

    struct Display: Codable {
        var width: Int
        var height: Int
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✕ " + message + "\n").utf8))
    exit(1)
}

func readConfig(_ bundle: URL) -> (url: URL, raw: [String: Any], config: Config) {
    let url = bundle.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let config = try? JSONDecoder().decode(Config.self, from: data)
    else { fail("\(url.path) is not a VM bundle's config") }
    return (url, raw, config)
}

// MARK: - run

@MainActor
func run(_ bundle: URL, cpus: Int?, memoryGB: Int?, window: Bool) -> Never {
    let config = readConfig(bundle).config
    guard let modelData = Data(base64Encoded: config.hardwareModel),
          let model = VZMacHardwareModel(dataRepresentation: modelData), model.isSupported else {
        fail("this Mac cannot run the bundle's hardware model")
    }
    guard let ecid = Data(base64Encoded: config.ecid),
          let identifier = VZMacMachineIdentifier(dataRepresentation: ecid) else {
        fail("the bundle's machine identifier does not read")
    }
    guard let mac = VZMACAddress(string: config.macAddress) else { fail("bad MAC address \(config.macAddress)") }

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = identifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.appendingPathComponent("nvram.bin"))

    let vm = VZVirtualMachineConfiguration()
    vm.platform = platform
    vm.bootLoader = VZMacOSBootLoader()
    vm.cpuCount = min(max(cpus ?? config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                      VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    let memory = memoryGB.map { UInt64($0) << 30 } ?? config.memorySize
    vm.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                        VZVirtualMachineConfiguration.maximumAllowedMemorySize)

    do {
        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.appendingPathComponent("disk.img"), readOnly: false)
        vm.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    } catch {
        fail("the disk did not open: \(error.localizedDescription)")
    }
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    network.macAddress = mac
    vm.networkDevices = [network]
    // A screen and the keys of its own: the guest's window server, which the
    // tests take instead of the person's. A laptop's screen by default,
    // 1440 by 900 points at twice the pixels, so a surface is laid out as on
    // a Mac rather than on a 960-point stand-in.
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: config.display?.width ?? 2880,
                                                           heightInPixels: config.display?.height ?? 1800,
                                                           pixelsPerInch: 220)]
    vm.graphicsDevices = [graphics]
    vm.keyboards = [VZMacKeyboardConfiguration()]
    vm.pointingDevices = [VZMacTrackpadConfiguration()]
    vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    do { try vm.validate() } catch { fail("the configuration is not valid: \(error.localizedDescription)") }

    let machine = VZVirtualMachine(configuration: vm)
    let watcher = Watcher()
    machine.delegate = watcher

    let app = NSApplication.shared
    app.setActivationPolicy(window ? .regular : .prohibited)
    if window {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = bundle.lastPathComponent
        w.contentView = view
        w.center()
        w.makeKeyAndOrderFront(nil)
        watcher.window = w
    }

    // A signal, or the parent going away, asks the guest to stop as its power
    // button would, and stops it outright if it has not gone in thirty seconds.
    func stopping() {
        guard !watcher.stopping else { return }
        watcher.stopping = true
        FileHandle.standardError.write(Data("stopping the guest\n".utf8))
        try? machine.requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            MainActor.assumeIsolated { machine.stop { _ in exit(0) } }
        }
    }
    for signo in [SIGINT, SIGTERM, SIGHUP] {
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { stopping() } }
        source.resume()
        watcher.sources.append(source)
    }
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parent.setEventHandler { MainActor.assumeIsolated { stopping() } }
    parent.resume()
    watcher.sources.append(parent)

    machine.start { result in
        switch result {
        case .success:
            print("started \(bundle.lastPathComponent) mac \(config.macAddress) cpus \(vm.cpuCount) memory \(vm.memorySize >> 30) GB")
            fflush(stdout)
        case .failure(let error):
            fail("the guest did not start: \(error.localizedDescription)")
        }
    }
    app.run()
    exit(0)
}

@MainActor
final class Watcher: NSObject, @preconcurrency VZVirtualMachineDelegate {
    var sources: [any DispatchSourceProtocol] = []
    var window: NSWindow?
    var stopping = false

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("stopped")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fail("the guest stopped with an error: \(error.localizedDescription)")
    }
}

// MARK: - clone

/// Every file copied on write (an APFS clone costs no space until written),
/// then a MAC address of its own, so its lease is never the original's. Made
/// beside its name and renamed into place whole: a clone that stopped halfway
/// is never one a later run boots.
func clone(_ from: URL, _ to: URL) {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: to.path) else { fail("\(to.path) already exists") }
    let partial = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).partial")
    try? fm.removeItem(at: partial)
    do {
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: from.path) {
            guard clonefile(from.appendingPathComponent(name).path, partial.appendingPathComponent(name).path, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        var (configURL, raw, _) = readConfig(partial)
        raw["macAddress"] = VZMACAddress.randomLocallyAdministered().string
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)
        try fm.moveItem(at: partial, to: to)
    } catch {
        try? fm.removeItem(at: partial)
        fail("could not clone: \(error.localizedDescription)")
    }
    print(to.path)
}

// MARK: - ip

/// The address the host's DHCP server leased to the bundle's MAC address
/// (the server keeps one entry per address and updates it in place). The
/// leases file writes each byte without its leading zero.
func ip(_ bundle: URL) {
    let mac = readConfig(bundle).config.macAddress.lowercased()
        .split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { exit(2) }
    for block in leases.components(separatedBy: "}") {
        guard block.contains("hw_address=1,\(mac)\n") else { continue }
        for line in block.split(separator: "\n") {
            let field = line.trimmingCharacters(in: .whitespaces)
            guard field.hasPrefix("ip_address="), field.count > "ip_address=".count else { continue }
            print(field.dropFirst("ip_address=".count))
            exit(0)
        }
    }
    exit(2)
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
@MainActor
func option(_ name: String) -> Int? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let value = Int(args[i + 1]) else { return nil }
    args.removeSubrange(i...(i + 1))
    return value
}
let cpus = option("--cpus")
let memoryGB = option("--memory-gb")
let window = args.contains("--window")
args.removeAll { $0 == "--window" }

switch (args.first, args.count) {
case ("run", 2): run(URL(fileURLWithPath: args[1]), cpus: cpus, memoryGB: memoryGB, window: window)
case ("clone", 3): clone(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]))
case ("ip", 2): ip(URL(fileURLWithPath: args[1]))
default:
    FileHandle.standardError.write(Data("""
    usage: lodestar-vm run <bundle> [--cpus N] [--memory-gb N] [--window]
           lodestar-vm clone <from> <to>
           lodestar-vm ip <bundle>

    """.utf8))
    exit(64)
}
