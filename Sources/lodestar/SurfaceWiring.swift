import AppKit
import LodestarCore

/// One voice on the lode-lode floor: a surface that may take the assent
/// gesture, or the dismissal, before the coach is asked. Each answer says
/// whether the gesture was taken.
struct Voice {
    let assent: () -> Bool
    let dismiss: () -> Bool
}

/// The seam between the engine, the glass, and the coach — wired in one
/// place, and the place has a harness on it.
///
/// This used to be a run of closures in the app delegate, which is where
/// the coach's first real bug lived: "who has the panel" was decided in
/// the untested part of the app, and one effect fell off the list. The
/// rule now is that everything these three objects say to each other is
/// said here. The app calls it once at launch; the scenario tests call it
/// for a stage of fakes — so what the tests drive is the wiring that
/// ships, not a transcription of it.
enum SurfaceWiring {
    /// `voices` are asked in order and the coach last, because every voice
    /// shares the lode-lode grammar and an assent can only ever mean one
    /// thing.
    static func wire(engine: HotkeyEngine, hud: HUD, coach: CoachController,
                     voices: [Voice], clock: Clock = .live) {
        coach.engineQuiet = { [weak engine] in engine?.isQuiet ?? false }
        coach.showChip = { [weak hud, weak coach] chip in
            // The keycap names the gesture the way the scroll guide's
            // "G G" does: two lodes, tapped. A blank cap read as a row
            // with no way in.
            //
            // Both rows carry the action the keys carry, so the chip can be
            // answered with the mouse when the gesture is inconvenient or
            // when a hand is already on it. The dismissal has a row of its
            // own rather than living only in the footer's prose: a way out
            // that cannot be clicked is not a way out for anyone reaching
            // for the pointer.
            // The offer is the title; the two answers are named as the
            // verbs they are. The footer says why, and what accepting
            // does, and nothing about the chip's own life.
            // Lodestar speaking: the offer as a sentence in the voice, the
            // address and the measurements beneath it in the interface's
            // face, and the two answers as key rows.
            // A keymap is drawn as keys; an offer with no keymap keeps its
            // address as words in the measurements line.
            let keymap = Coach.Keymap.parse(chip.headline)
            hud?.showVoice(
                sentence: chip.sentence.isEmpty ? chip.headline : chip.sentence,
                keymap: keymap,
                detail: keymap == nil ? Coach.sentenceCase("\(chip.headline) · \(chip.evidence)") : chip.evidence,
                rows: [
                    GuideRow(keys: ["lode", "lode"], label: "Accept",
                             action: { [weak coach] in coach?.lodeDoubleTapped() }),
                    GuideRow(keys: ["lode", "⌫"], label: "Decline",
                             action: { [weak coach] in _ = coach?.lodeDelete() }),
                ],
                owner: .coach)
        }
        // A decline is answered in the voice too, briefly, and then the
        // glass is clear: the offer sleeps a season.
        coach.note = { [weak hud] sentence in
            hud?.showVoice(sentence: sentence, detail: nil, rows: [], owner: .flash,
                           seconds: Readability.flashSeconds(for: sentence))
        }
        coach.hideChip = { [weak hud] in hud?.hide() }
        coach.ownsSurface = { [weak hud] in hud?.owner == .coach }
        coach.inputWasHuman = { [weak engine] in engine?.actingInputWasHuman ?? true }
        coach.humanIdle = { [weak engine] in
            guard let engine else { return 0 }
            return clock.now().timeIntervalSince(engine.lastHumanInputAt)
        }
        coach.flash = { [weak hud] text in hud?.flash(text) }
        // A flash steals the glass without going through the engine's
        // surface claim; the chip must not outlive its own pixels.
        hud.onTakeover = { [weak coach] in coach?.surfaceClaimed() }
        engine.onSurfaceClaimed = { [weak coach] in coach?.surfaceClaimed() }
        engine.onLodeDoubleTap = { [weak coach] in
            for voice in voices where voice.assent() { return }
            coach?.lodeDoubleTapped()
        }
        engine.coachDelete = { [weak coach] in
            for voice in voices where voice.dismiss() { return true }
            return coach?.lodeDelete() ?? false
        }
    }
}
