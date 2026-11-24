import AppKit

// A stand-in app for the window tests: a few plain windows of known titles
// and frames, for Lodestar's real window actions to move. Started by the
// tests, never by a person.
//
//   WindowFixture --frames x,y,w,h[;x,y,w,h...] [--titles a,b,c] [--visible]
//
// Frames are in the window server's coordinates (origin top left), the
// ones Lodestar moves in. The windows are invisible unless asked for:
// fully transparent and deaf to the mouse, so a frame that lands on a
// real display shows nothing there and takes no click. The app never
// becomes active: no Dock tile, no menu bar, no focus taken. It prints
// "ready" and each window's server id, one line, then waits; its windows
// go when standard input closes, which is when the test that started it
// is done with it, however that test ends.

final class FixtureWindow: NSWindow {
    // A window here goes exactly where it is told, even off every display:
    // the tests check where Lodestar put it, not where AppKit would have.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }

    // AppKit's own answer to a size write keeps the old size whenever the
    // new one is smaller and the window stands on no display, so the size
    // is taken here, its top-left corner held where it is, as an app on a
    // real display takes it.
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute == .size, let size = (value as? NSValue)?.sizeValue else {
            return super.accessibilitySetValue(value, forAttribute: attribute)
        }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height),
                 display: false)
    }
}

func rect(_ text: Substring) -> CGRect? {
    let parts = text.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

var frames: [CGRect] = []
var titles: [String] = []
var visible = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--frames": frames = (arguments.next() ?? "").split(separator: ";").compactMap(rect)
    case "--titles": titles = (arguments.next() ?? "").split(separator: ",").map(String.init)
    case "--visible": visible = true
    default: break
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// The window server's y runs down from the top of the main display;
// AppKit's runs up from its bottom.
let mainHeight = NSScreen.screens.first?.frame.height ?? 0
var windows: [FixtureWindow] = []
for (index, frame) in frames.enumerated() {
    let cocoa = NSRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    let window = FixtureWindow(contentRect: cocoa,
                               styleMask: [.titled, .resizable, .miniaturizable, .closable],
                               backing: .buffered, defer: false)
    window.title = index < titles.count ? titles[index] : "Fixture \(index + 1)"
    window.isReleasedWhenClosed = false
    if !visible {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
    }
    window.setFrame(cocoa, display: false)
    window.orderFrontRegardless()
    windows.append(window)
}

print("ready " + windows.map { String($0.windowNumber) }.joined(separator: " "))
fflush(stdout)

Thread.detachNewThread {
    while readLine() != nil {}
    DispatchQueue.main.async { exit(0) }
}
app.run()
