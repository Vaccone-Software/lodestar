# 16 · Sound

What Lodestar sounds like: three sounds, one voice, drawn from a time and a material.

## What it is for

**The ideal.**
- **A thing, touched.** Lodestar looks like matte ceramic keys in one light, so it sounds like an object struck by a hand: close and physical, not a tone switched on.
- **Matte, so dry.** It is short and close, with no hall, no shimmer and no glassy ring. The Mac's own alerts are glass and metal (Glass, Tink, Ping), and Lodestar is told from them in its first few milliseconds.
- **Pitched enough to carry a fifth.** Listening and Landed say "up" and "down", which a pure knock cannot do.
- **Quiet and rare.** There are three sounds, each one fact the eye cannot see, and the ideal does not add a fourth.
- **From a lineage, not a costume.** The voice takes a material and an era whose values match Lodestar's (made, precise, for daily work), and imitates nothing so closely that it names a product.

What the sounds mean does not change: DESIGN.md, "Two notes, and the silence between them".
- **The alert** is Lodestar's identity in the Mac's Sounds.
- **Listening** is a fifth rising on the first buffer with signal.
- **Landed** is the same fifth falling.
- `app.sounds` turns them off together.

## Origin

- **The strike** (15 September 2026) is pure sines at 1 : φ : φ², "no sample of a real thing, so it names no object", chosen by ear from five candidates. `tools/sound/lodestar.py` renders it.
- **Glazed** (the ceramic prototype, 21 October 2026) is the same strike with a bright tick at its attack. It was chosen over Porcelain, Bisque and Tile, but the owner could not hear it apart from the strike. A variant that changes only the first milliseconds is not a new voice.
- **This contract starts again from the ideal** (owner, 24 October 2026). The current sounds are not kept by default, and alternatives are explored that are more distinctly Lodestar's, drawn from particular times and materials.

## The voices under review

Each is synthesized from how its material rings: the ratios between its overtones, how fast each fades, and what the strike adds. The levels are matched by energy, so no voice wins by being louder.

| Voice  | Material and time                              | What it is                                                         |
| ------ | ---------------------------------------------- | ------------------------------------------------------------------ |
| Bisque | unglazed stoneware, American studio pottery, 1950s | inharmonic cup modes (1 : 2.32 : 4.25 : 6.63), the highs dying first, a low knock |
| Tine   | struck steel tine, the electric piano, 1965    | a carrier and a modulator at one pitch, the modulation falling in 30 ms, a bright bar partial at 7.1 |
| Maple  | hard maple, the wooden block, early 1900s      | free-bar modes (1 : 2.76 : 5.4), decays under 50 ms, a click        |
| Felt   | felt on a string, the muted upright, 1940s     | six harmonics rolled off by a felt hammer, two strings 1.5 cents apart |
| Today  | pure tones, the shipped Glazed strike          | 1 : φ : φ², an 18-cent settle, a tick at the attack                 |

## Values (once a voice is chosen)

- **Register:** the alert on A5 (880 Hz). Listening is A5 then E6, 90 ms apart; Landed is E6 then A5. Listening and Landed play 4.4 dB under the alert.
- **Level:** peaks at −9 dBFS, matched to the Mac's alerts.
- **Length:** the body is 20 dB down by 200 ms. Nothing rings past 600 ms.
- **No reverb.** The room is the listener's.
- **Files:** `packaging/Lodestar.aiff`, `Listening.aiff` and `Landed.aiff`, 44.1 kHz, 16-bit, rendered by `tools/sound/lodestar.py` with seeded noise, so every render is the same bytes.

## Rules

1. **One voice.** The three sounds are one struck thing at two pitches.
2. **A material, not a theme.** The voice says what it is made of, not what product it came from.
3. **Dry and short.** No tail longer than 600 ms, and no reverb.
4. **Three sounds.** A fourth needs DESIGN.md's test: one fact the eye cannot see, asked for by the hand.
5. **The ear outranks the rule.** The choice is made by listening, and this contract records it.

## Enforcement

- **The render is the same bytes every time** (a hash test on the script's output).
- **Each file:** peak −9 dBFS ± 0.5, body −20 dB by 200 ms, silent by 600 ms, as measured by a test that reads the AIFF.
- **Listening and Landed:** their two onsets are 90 ms apart, and their pitches are a fifth apart within 5 cents (an FFT on each onset).
- **The alert** is the copy the app installs in `~/Library/Sounds` (an existing test, kept).

## Renders

The review page plays every voice live (Web Audio, from the same parameters the script will use).

## Status

Drafted 24 October 2026. Main plays Glazed.

## Decided in review
