import ApplicationServices

// The single private call this project allows itself — the same one, and the
// only one, widely relied upon in this category. It bridges an AX window element to its
// CGWindowID: the durable handle marks and breaths pin to. Read-only, and it
// works with SIP fully enabled.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// The window-server ID of an AX window element, or nil if the element does
/// not resolve to a real window.
public func windowID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
    return id
}
