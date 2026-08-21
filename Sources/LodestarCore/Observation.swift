import ApplicationServices
import Foundation

/// Wraps AXObserver for one process; delivers notifications on the main run loop.
public final class AppObserver {
    public typealias Handler = (_ notification: String, _ element: AXUIElement) -> Void

    public let pid: pid_t
    private var observer: AXObserver?
    private let handler: Handler

    public init?(pid: pid_t, handler: @escaping Handler) {
        self.pid = pid
        self.handler = handler
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.handler(notification as String, element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    @discardableResult
    public func watch(_ notification: String, on element: AXUIElement) -> Bool {
        guard let observer else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        return AXObserverAddNotification(observer, element, notification as CFString, refcon) == .success
    }

    /// Drop one registration. The observer's client-side table holds an
    /// entry — element token included — per watch for the observer's whole
    /// life, so a window's registrations must die with the window or a
    /// browser churning hundreds of them grows the table for weeks.
    public func unwatch(_ notification: String, on element: AXUIElement) {
        guard let observer else { return }
        AXObserverRemoveNotification(observer, element, notification as CFString)
    }

    public func invalidate() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    deinit { invalidate() }
}
