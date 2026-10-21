"""Lodestar's sound cues: one strike, partials at 1 : φ : φ², the pill's
proportion table as pitch. Pure sines under an envelope, plus a few
milliseconds of noise at the attack; no reverb, no sample of a real thing,
so it names no object.

The voice is Glazed. The first one, Star (2026-09-15, chosen by ear from
five candidates and four refinements), was the same strike with a 6 ms
rounded attack and a 25-cent settle; Ceramic keeps its proportions and
changes only the material it belongs to: a short bright tick at the attack,
as glaze meets glaze, a settle of 18 cents, a 2 ms linear attack, and a
slightly shorter body and tail. Glazed was chosen by ear from four
ceramic voicings synthesized beside the strike (DESIGN.md, "Ceramic").

    python3 tools/sound/lodestar.py          # renders into packaging/

Three cues, one voice:

  Lodestar   the alert: one strike at A5, level 1 (peak -9 dBFS, matched to
             the alerts it sits beside; installs to ~/Library/Sounds, which
             is where Sound settings looks)
  Listening  two strikes at level 0.5, a fifth below A5 then A5, 80 ms
             apart: the microphone is live (peak -12 dBFS)
  Landed     the same two reversed: the words landed (peak -12 dBFS)

44.1 kHz 16-bit big-endian stereo AIFF, converted with `afconvert`. Every
render is the same bytes: the tick's noise is seeded, and nothing else
is random. Sounds.swift plays Listening and Landed; the app installs
Lodestar.aiff. Each strike is, per partial [ratio, amp, tau seconds]:

    envelope  a linear ramp 0 to 1 over `attack`, then an exponential
              approach to 0 with time constant tau (the Web Audio
              setTargetAtTime of the approved prototype); the fundamental
              approaches the tail level instead, and from attack + 4 tau
              decays to 0 with the tail's tau
    pitch     the two lower partials start `drop_cents` sharp and settle
              onto their pitch over `drop_ms`, the way a struck thing does
    width     the second partial is 0.35 ms late on the right and the third
              on the left, a third of a millisecond of stereo width
"""
import math, os, random, struct, subprocess, sys, wave

SR = 44100
PHI = (1 + 5 ** 0.5) / 2
A5 = 880.0
FIFTH = 1.5

GLAZED = dict(
    partials=[(1.0, 1.0, 0.07), (PHI, 0.40, 0.05), (PHI ** 2, 0.16, 0.03)],
    drop_cents=18.0, drop_ms=25.0, attack=0.002,
    tail=(0.05, 0.28),
    # white noise through a bandpass: (centre Hz, Q, gain, seconds to silence)
    tick=(6500.0, 3.0, 0.35, 0.006),
)
VOICE = GLAZED
WIDTH = 0.00035
SILENCE = 1e-4           # where an exponential ramp "to silence" lands
NOISE_SEED = 0x6C6F6465  # "lode"


def envelope(t, attack, tau, tail=None):
    """The approved prototype's envelope at time t (seconds from the strike)."""
    if t < 0:
        return 0.0
    if t < attack:
        return t / attack
    t -= attack
    level = tail[0] if tail else 0.0
    if tail and t > 4 * tau:
        return (level + (1 - level) * math.exp(-4)) * math.exp(-(t - 4 * tau) / tail[1])
    return level + (1 - level) * math.exp(-t / tau)


def phase(f, t, cents, drop_s):
    """A settling frequency integrated, so the drop never clicks."""
    if not cents:
        return 2 * math.pi * f * t
    k = 2 ** (cents / 1200) - 1
    u = min(t / drop_s, 1.0)
    return 2 * math.pi * f * t + 2 * math.pi * f * k * drop_s * (u - u * u / 2)


def partial_length(voice, index):
    """Seconds until the partial is below -65 dB and cut."""
    _, _, tau = voice["partials"][index]
    if index == 0:
        return voice["attack"] + 4 * tau + voice["tail"][1] * 5
    return voice["attack"] + tau * 9


def strike(voice, f0, level, side, seed):
    """One strike at pitch f0: a list of samples for one channel."""
    n = int(SR * max(partial_length(voice, i) for i in range(3)))
    out = [0.0] * n
    drop_s = voice["drop_ms"] / 1000
    for index, (ratio, amp, tau) in enumerate(voice["partials"]):
        f = f0 * ratio
        delay = WIDTH if (index == 1 and side == "R") or (index == 2 and side == "L") else 0.0
        cents = voice["drop_cents"] if index < 2 else 0.0
        length = int(SR * partial_length(voice, index))
        for i in range(min(length, n)):
            t = i / SR - delay
            if t < 0:
                continue
            env = envelope(t, voice["attack"], tau, tail=voice["tail"] if index == 0 else None)
            out[i] += level * amp * env * math.sin(phase(f, t, cents, drop_s))
    # the tick: noise through an RBJ bandpass (constant 0 dB peak), decaying
    # exponentially to silence
    centre, q, gain, seconds = voice["tick"]
    rng = random.Random(seed)
    w0 = 2 * math.pi * centre / SR
    alpha = math.sin(w0) / (2 * q)
    b0, b2 = alpha, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    x1 = x2 = y1 = y2 = 0.0
    g0 = gain * level
    for i in range(int(SR * seconds)):
        x = rng.uniform(-1, 1)
        y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x, y1, y
        out[i] += y * g0 * (SILENCE / g0) ** (i / (SR * seconds))
    return out


def mix(into, samples, start):
    offset = int(round(SR * start))
    if offset + len(samples) > len(into):
        into.extend([0.0] * (offset + len(samples) - len(into)))
    for i, v in enumerate(samples):
        into[offset + i] += v


def cue(notes, body=None):
    """notes: [(start s, pitch Hz, level)]. Two channels, each a list."""
    chans = []
    for side in ("L", "R"):
        samples = []
        for number, (start, pitch, level) in enumerate(notes):
            # the same tick in both channels: it is centred
            mix(samples, strike(VOICE, pitch, level, side, NOISE_SEED + number), start)
        if body is not None:
            samples = samples[:int(SR * body)]
            fade = int(SR * 0.03)
            for k in range(min(fade, len(samples))):
                samples[len(samples) - 1 - k] *= k / fade
        chans.append(samples)
    return chans


def write(path, chans, peak_db, tail_silence=0.35):
    n = max(len(c) for c in chans) + int(SR * tail_silence)
    outs = [c + [0.0] * (n - len(c)) for c in chans]
    fade = int(SR * 0.006)
    for o in outs:
        for k in range(fade):
            o[n - 1 - k] *= k / fade
    m = max(abs(x) for o in outs for x in o) or 1
    g = (10 ** (peak_db / 20)) / m
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            for o in outs:
                frames += struct.pack("<h", int(round(max(-1, min(1, o[i] * g)) * 32767)))
        w.writeframes(bytes(frames))


# name, notes (start, pitch, level), peak dBFS, body seconds before the 0.35 s of silence
GAP = 0.08
CUES = [
    ("Lodestar", [(0.0, A5, 1.0)], -9.0, None),
    ("Listening", [(0.0, A5 / FIFTH, 0.5), (GAP, A5, 0.5)], -12.0, 0.54),
    ("Landed", [(0.0, A5, 0.5), (GAP, A5 / FIFTH, 0.5)], -12.0, 0.54),
]

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "..", "packaging")
    scratch = os.environ.get("TMPDIR", "/tmp")
    for name, notes, peak, body in CUES:
        wav = os.path.join(scratch, f"{name}.wav")
        write(wav, cue(notes, body), peak)
        subprocess.run(["afconvert", "-f", "AIFF", "-d", "BEI16", wav, os.path.join(out, f"{name}.aiff")],
                       check=True)
        os.remove(wav)
        print(name)
