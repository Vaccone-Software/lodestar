"""Lodestar's alert sound: one strike, partials at 1 : φ : φ², the pill's
proportion table as pitch. Pure sines under an envelope, no reverb, no
sample of a real thing, so it names no object. Chosen by ear on
2026-09-15 from five candidates (Star, Lode, Settle, Wind, Glass) and
four refinements of Star; the shipped one combines a rounded attack with
a 25-cent settle (something touched, not switched on), a quiet long tail
on the fundamental alone (short to the hand, finished to the room), and a
third of a millisecond of stereo width. Star φ, everything derived by φ
including loudness, was tried and set aside: brighter and thinner, and
the ear outranks the rule.

    python3 tools/sound/lodestar.py && afconvert -f AIFF -d BEI16 Lodestar.wav packaging/Lodestar.aiff

Peak -9 dBFS, matched to the alerts it sits beside; body 20 dB down by
~200 ms; 44.1 kHz 16-bit stereo. It ships in the bundle's Resources and
installs to ~/Library/Sounds, which is where Sound settings looks.
"""
import math, wave, struct
SR = 44100; PHI = (1 + 5 ** 0.5) / 2; A5 = 880.0; TAU = 0.11

def partial(f, amp, tau, attack=0.003, shaped=False, drop_cents=0.0, drop_ms=0.0, delay=0.0, tail=None):
    """One partial. `tail` = (level, tau) adds a quiet second decay stage.
    `drop_cents` over `drop_ms`: the pitch settles down onto f, the way a
    struck thing does. `delay` shifts it in time (for stereo width)."""
    dur = tau * 6 if tail is None else tail[1] * 5
    def sample(t):
        t -= delay
        if t < 0 or t > dur: return 0.0
        if shaped: env = 0.5 - 0.5 * math.cos(math.pi * min(t, attack) / attack)
        else: env = t / attack if t < attack else 1.0
        decay = math.exp(-t / tau)
        if tail is not None: decay += tail[0] * math.exp(-t / tail[1])
        # phase integrates a settling frequency so the drop never clicks
        if drop_cents and t < drop_ms / 1000:
            u = t / (drop_ms / 1000)
            fi = f * 2 ** ((drop_cents / 1200) * (1 - u))
            phase = 2 * math.pi * f * t + 2 * math.pi * f * (2 ** (drop_cents / 1200) - 1) * (drop_ms / 1000) * (u - u * u / 2)
        else:
            phase = 2 * math.pi * f * t + (2 * math.pi * f * (2 ** (drop_cents / 1200) - 1) * (drop_ms / 1000) * 0.5 if drop_cents else 0)
        return amp * env * decay * math.sin(phase)
    return sample, dur

def render(name, left, right=None, peak_db=-9.0, tailsil=0.35):
    chans = [left] + ([right] if right else [])
    end = max(e for c in chans for _, e in c); n = int(SR * (end + tailsil))
    outs = [[sum(v(i / SR) for v, _ in c) for i in range(n)] for c in chans]
    fade = int(SR * 0.006)
    for o in outs:
        for k in range(fade): o[n - 1 - k] *= k / fade
    m = max(abs(x) for o in outs for x in o) or 1
    g = (10 ** (peak_db / 20)) / m
    with wave.open(f"{name}.wav", "wb") as w:
        w.setnchannels(len(outs)); w.setsampwidth(2); w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            for o in outs: frames += struct.pack("<h", int(max(-1, min(1, o[i] * g)) * 32767))
        w.writeframes(bytes(frames))
    print(name)


d = 0.00035
def voices(side):
    f0 = partial(A5, 1.0, 0.08, attack=0.006, shaped=True, drop_cents=25, drop_ms=25,
                 tail=(10 ** (-24 / 20), 0.35))
    p1 = partial(A5 * PHI, 0.45, 0.08 * 0.72, attack=0.006, shaped=True, drop_cents=25, drop_ms=25,
                 delay=d if side == "R" else 0.0)
    p2 = partial(A5 * PHI ** 2, 0.18, 0.08 * 0.45, attack=0.006, shaped=True,
                 delay=d if side == "L" else 0.0)
    return [f0, p1, p2]

if __name__ == "__main__":
    render("Lodestar", voices("L"), voices("R"))
