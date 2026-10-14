import CoreGraphics
import Darwin

/// `CGWindowListCreateImage`, reached at run time.
///
/// The SDK marks it unavailable once the deployment target passes macOS 15,
/// and Lodestar's floor is 27. The function itself is still in CoreGraphics
/// and is what every build before the floor moved called, on every macOS:
/// a synchronous composite, fast enough to take inside Select's entry
/// before the overlay exists. ScreenCaptureKit's replacement is async and
/// would reorder that entry, so the move is its own change. Until then the
/// call is looked up by name; if a future macOS drops it, every capture
/// answers nil, which every caller already treats as "no pixels" (the
/// accessibility walk, or a printed "capture failed").
public enum WindowCapture {
    private typealias Create = @convention(c) (
        CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private static let create: Create? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Create.self)
    }()

    /// Whether this macOS still has the function.
    public static var isAvailable: Bool { create != nil }

    /// The same arguments and answer as `CGWindowListCreateImage`.
    public static func image(_ bounds: CGRect, _ list: CGWindowListOption,
                             _ window: CGWindowID, _ options: CGWindowImageOption) -> CGImage? {
        create?(bounds, list, window, options)?.takeRetainedValue()
    }
}
