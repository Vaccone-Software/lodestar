import AppKit
import Carbon
import LodestarCore

/// Secure input left on, in the app: samples it every two seconds, asks
/// `SecureInputNotice` whether it is stuck, and keeps the held key up while
/// it is. A click on it brings the holder forward, where its password
/// field is; with the holder in front the notice goes quiet, which is the
/// right reading of a field you are now looking at.
///
/// Independent of health: the health monitor samples secure input for the
/// record only while health is on, and a dead gesture needs explaining
/// either way.
final class SecureInputController {
    /// One look at the machine; the tests replace it.
    var read: () -> SecureInputNotice.Sample = SecureInputProbe.sample
    var show: (_ holder: SecureInputNotice.Holder, _ onClick: @escaping () -> Void) -> Void = { _, _ in }
    /// The notice goes; `keysBack` when secure input itself ended, so the
    /// key lights before it leaves.
    var hide: (_ keysBack: Bool) -> Void = { _ in }
    var bringForward: (Int32) -> Void = { pid in
        if let app = NSRunningApplication(processIdentifier: pid) { SystemEvents.activate(app) }
    }

    static let interval: TimeInterval = 2
    private var notice = SecureInputNotice(ownPID: ProcessInfo.processInfo.processIdentifier)
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One sample; the harness calls it directly.
    func tick() {
        switch notice.sample(read()) {
        case .show(let holder):
            Log.info("secure input", ["notice": "shown"])
            show(holder) { [weak self] in self?.bringForward(holder.pid) }
        case .hide(let keysBack):
            Log.info("secure input", ["notice": keysBack ? "ended" : "quiet"])
            hide(keysBack)
        case .none:
            break
        }
    }
}

/// The machine's side: whether secure input is on, who holds it, what is in
/// front, and whether the screen is locked. The holder's pid is in the
/// session dictionary, read only while secure input is on.
enum SecureInputProbe {
    static func sample() -> SecureInputNotice.Sample {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard IsSecureEventInputEnabled() else {
            return .init(on: false, holder: nil, frontPID: front, screenLocked: false)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        // The lock key is absent entirely while the screen is unlocked.
        let locked = (session["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
        let holder = (session["kCGSSessionSecureInputPID"] as? Int).flatMap { pid -> SecureInputNotice.Holder? in
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return nil }
            return .init(pid: pid_t(pid), name: app.localizedName ?? "An app", bundleID: app.bundleIdentifier)
        }
        return .init(on: true, holder: holder, frontPID: front, screenLocked: locked)
    }
}
