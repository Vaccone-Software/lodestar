import AppKit

/// The fade, applied to a bar's footer of keys: the legend stays
/// invisible for the delay `SurfaceFade` earned and then arrives, so a
/// hand that knows its keys never reads them and a hand that hesitates
/// gets them after recall had its chance. Zero delay paints at once, the
/// way every footer always did.
final class FooterFade {
    private var reveal: DispatchWorkItem?

    func apply(to footer: NSTextField, delay: TimeInterval) {
        reveal?.cancel()
        reveal = nil
        guard delay > 0 else {
            footer.alphaValue = 1
            return
        }
        footer.alphaValue = 0
        let work = DispatchWorkItem { [weak footer] in
            guard let footer else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                footer.animator().alphaValue = 1
            }
        }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
