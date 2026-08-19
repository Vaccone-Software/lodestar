import Foundation

/// Work that must not happen inside the event tap.
///
/// The tap callback runs on the main run loop, and the only thing it owes
/// the window server is a verdict: swallow this key, or pass it on. Until
/// it answers, keyboard delivery is stalled for *every* app on the machine,
/// and if it overruns the system's patience macOS disables the tap outright
/// — at which point the rest of the chain lands as literal text in whatever
/// is in front.
///
/// Anything that talks to another application is unbounded by nature. An
/// accessibility call against an app that has stopped answering blocks for
/// the full messaging timeout — one second, per call, and restoring a
/// layout makes dozens of them. A full-display capture is bounded only by
/// the compositor. None of it may run before the verdict.
///
/// 0.18.0 established this for the effect list, in `HotkeyEngine.dispatch`,
/// and missed the other door: `EngineWorld` callbacks are invoked from
/// inside `EngineCore.keyDown`, which is to say *before* there is an effect
/// list to filter. Same rule, two paths, so it gets one name — a later hand
/// reaching for accessibility in a world callback should find the reason
/// written down rather than rediscover it from a bug report.
///
/// The split is always the same shape. The *decision* is cheap and stays
/// where it is — does a breath exist at this path, does this label match,
/// is there a focused window — and only the doing moves. The state machine
/// advances synchronously and stays exact; only the conversation with other
/// apps lags by one turn of the run loop.
///
/// **Not** for work whose ordering against the user's next keystroke
/// matters. The clipboard verbs synthesize a ⌘V through `CGEvent.post`, and
/// ordering between a run-loop source and a dispatched block is not
/// guaranteed, so those stay synchronous on purpose.
public enum OffTap {
    /// Run `work` on the next turn of the main run loop, after the tap has
    /// returned its verdict. Callers that can be superseded in the meantime
    /// — a mode re-entered, a mode left — carry their own generation check
    /// inside `work`; this makes no attempt to guess at staleness.
    public static func run(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
