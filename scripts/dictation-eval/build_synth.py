#!/usr/bin/env python3
"""Synthesize the dictation corpus with macOS `say` and write manifest.json.

Outputs (relative to this folder):
  corpus/utterances.json         ground truth per utterance (voice independent)
  audio/synthetic/<uid>__<voice>.wav
  audio/typing/<uid>__<voice>__typing.wav   pause items with keyboard clicks in the pauses
  audio/longform/long<k>__<voice>.wav       60-120 s concatenations
  manifest.synthetic.json        entries for all of the above
  manifest.json                  synthetic + human (if manifest.human.json exists)

Pure standard library (wave, array, random). 16 kHz mono 16-bit PCM.
"""
import array, json, math, os, random, re, subprocess, sys, tempfile, wave, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from corpus_src import UTTERANCES, USER_NAMES, EXTRA_NAMES, TERMS, PRONUNCIATION  # noqa: E402

SR = 16000
PAD_MS = 250            # silence before and after each clip
NOISE_SIGMA = 8.0       # ~ -72 dBFS noise floor so no clip is digital zero
PAUSE_MIN_MS = 1000     # silence runs this long are the inserted pauses

# key, `say` name, locale, gender, quality note
VOICES = [
    ("samantha", "Samantha", "en-US", "F", "compact (AVSpeech quality 1)"),
    ("daniel", "Daniel", "en-GB", "M", "super-compact"),
    ("karen", "Karen", "en-AU", "F", "super-compact"),
    ("reed", "Reed (English (US))", "en-US", "M", "Eloquence (formant synth)"),
    ("moira", "Moira", "en-IE", "F", "super-compact"),
    ("aman", "Aman", "en-IN", "M", "compact"),
]
VOICE = {v[0]: v for v in VOICES}
LONGFORM_VOICES = ["samantha", "daniel", "karen", "reed", "moira"]

MARK = re.compile(r"\{(p|trail)(\d+)\}")
rng = random.Random(20261002)


# ---------------------------------------------------------------- text ----
def strip_marks(text):
    return re.sub(r"\s+", " ", MARK.sub(" ", text)).strip()


def _sub_word(text, written, spoken):
    return re.sub(r"(?<![A-Za-z0-9])" + re.escape(written) + r"(?![A-Za-z0-9])", lambda _: spoken, text)


def tts_text(text):
    out = []
    for piece in re.split(r"(\{(?:p|trail)\d+\})", text):
        m = MARK.fullmatch(piece)
        if m:
            out.append(f" [[slnc {m.group(2)}]] ")
            continue
        for written, spoken in sorted(TERMS.items(), key=lambda kv: -len(kv[0])):
            piece = _sub_word(piece, written, spoken)
        for written, spoken in PRONUNCIATION:
            piece = _sub_word(piece, written, spoken)
        out.append(piece)
    return re.sub(r" +", " ", "".join(out)).strip()


def name_spans(text):
    out = []
    for name in sorted(USER_NAMES + EXTRA_NAMES, key=len, reverse=True):
        for m in re.finditer(r"(?<![A-Za-z0-9])" + re.escape(name) + r"(?![A-Za-z0-9])", text):
            if any(s["start"] < m.end() and m.start() < s["end"] for s in out):
                continue  # inside a longer name already tagged
            out.append({"name": name, "start": m.start(), "end": m.end(), "in_user_list": name in USER_NAMES})
    return sorted(out, key=lambda s: s["start"])


def terms_in(text):
    return [{"written": w, "spoken": s} for w, s in TERMS.items() if w in text and w != "swift build"] + \
           ([{"written": "swift build", "spoken": "swift build"}] if "swift build" in text else [])


def pause_anchors(text):
    """For each pause marker: index of the whitespace token just before it in
    the marker-free text, plus the words around it."""
    anchors, tokens = [], []
    for piece in re.split(r"(\{(?:p|trail)\d+\})", text):
        m = MARK.fullmatch(piece)
        if m:
            kind = "mid" if m.group(1) == "p" else "trailing"
            anchors.append({"kind": kind, "planned_ms": int(m.group(2)), "after_token": len(tokens) - 1,
                            "word_before": tokens[-1] if tokens else None})
        else:
            tokens += piece.split()
    for a in anchors:
        a["word_after"] = tokens[a["after_token"] + 1] if a["after_token"] + 1 < len(tokens) else None
    return anchors


# --------------------------------------------------------------- audio ----
def read_wav(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        a = array.array("h")
        a.frombytes(w.readframes(w.getnframes()))
    return a


def write_wav(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(samples.tobytes())


def say(voice_key, text):
    fd, tmp = tempfile.mkstemp(suffix=".wav"); os.close(fd)
    subprocess.run(["say", "-v", VOICE[voice_key][1], "--data-format=LEI16@16000", "-o", tmp, text], check=True)
    a = read_wav(tmp); os.unlink(tmp)
    return a


def silence_runs(a, min_ms, thresh=60, frame_ms=10):
    f = SR * frame_ms // 1000
    quiet = []
    for i in range(0, len(a), f):
        seg = a[i:i + f]
        quiet.append(max(abs(x) for x in seg) < thresh if seg else True)
    runs, start = [], None
    for i, q in enumerate(quiet + [False]):
        if q and start is None:
            start = i
        elif not q and start is not None:
            if (i - start) * frame_ms >= min_ms:
                runs.append(((start * frame_ms) / 1000, (i * frame_ms) / 1000))
            start = None
    return runs


def trim_edges(a, thresh=60):
    lo, hi = 0, len(a)
    while lo < hi and abs(a[lo]) < thresh: lo += 1
    while hi > lo and abs(a[hi - 1]) < thresh: hi -= 1
    return a[lo:hi], lo


def silence(ms):
    return array.array("h", [0]) * int(SR * ms / 1000)


def add_noise(a, sigma=NOISE_SIGMA, seed=0):
    r = random.Random(seed)
    return array.array("h", (max(-32768, min(32767, x + int(round(r.gauss(0, sigma))))) for x in a))


def mix_typing(a, windows, seed):
    """Keyboard-like clicks (press + release transients) inside each window (s)."""
    r = random.Random(seed)
    out = array.array("h", a)
    for (t0, t1) in windows:
        t = t0 + 0.15
        while t < t1 - 0.15:
            for (dt, amp) in ((0.0, r.uniform(2200, 4200)), (r.uniform(0.06, 0.11), r.uniform(1000, 2200))):
                i0 = int((t + dt) * SR)
                prev = 0.0
                for k in range(int(0.014 * SR)):
                    n = r.uniform(-1, 1)
                    hp = n - 0.85 * prev; prev = n          # brighten the noise
                    v = amp * hp * math.exp(-k / (0.0022 * SR))
                    j = i0 + k
                    if 0 <= j < len(out):
                        out[j] = max(-32768, min(32767, out[j] + int(v)))
            t += r.uniform(0.11, 0.26)
    return out


_cache = {}


def render(u, voice_key):
    """Render utterance u in a voice. Returns (samples, pauses) with pause
    times in seconds relative to the returned samples (already padded)."""
    key = (u["id"], voice_key)
    if key in _cache:
        return _cache[key]
    raw = say(voice_key, tts_text(u["text"]))
    body, _ = trim_edges(raw)
    anchors = pause_anchors(u["text"])
    runs = silence_runs(body, PAUSE_MIN_MS)
    trailing = [a for a in anchors if a["kind"] == "trailing"]
    mids = [a for a in anchors if a["kind"] == "mid"]
    if trailing:   # trim_edges ate the trailing silence: put it back
        body = body + silence(trailing[0]["planned_ms"])
    if len(runs) != len(mids):
        print(f"WARN {u['id']} {voice_key}: {len(runs)} silence runs for {len(mids)} pauses: {runs}")
    pad = PAD_MS / 1000
    pauses = []
    for a, (s, e) in zip(mids, runs):
        pauses.append(dict(a, start_s=round(s + pad, 3), end_s=round(e + pad, 3), dur_s=round(e - s, 3)))
    for a in trailing:
        speech_end = (len(body) / SR) - a["planned_ms"] / 1000
        pauses.append(dict(a, start_s=round(speech_end + pad, 3), end_s=round(len(body) / SR + pad, 3),
                           dur_s=round(a["planned_ms"] / 1000, 3)))
    out = silence(PAD_MS) + body + silence(PAD_MS)
    _cache[key] = (out, pauses)
    return _cache[key]


# ------------------------------------------------------------ manifest ----
def ground_truth(u):
    verbatim = strip_marks(u["text"])
    clean = u["clean"] or verbatim
    return {
        "utterance_id": u["id"],
        "category": u["category"],
        "tags": u["tags"],
        "reference_verbatim": verbatim,
        "reference_clean": clean,
        "names": name_spans(clean),
        "names_verbatim": name_spans(verbatim),
        "terms": terms_in(clean),
        "tts_text": tts_text(u["text"]),
    }


def voice_meta(k):
    v = VOICE[k]
    return {"voice": k, "voice_name": v[1], "locale": v[2], "gender": v[3], "voice_quality": v[4]}


def main():
    os.chdir(HERE)
    gts = {u["id"]: ground_truth(u) for u in UTTERANCES}
    os.makedirs("corpus", exist_ok=True)
    with open("corpus/utterances.json", "w") as f:
        json.dump([dict(gts[u["id"]], source_text=u["text"]) for u in UTTERANCES], f, indent=2)

    entries = []
    # Each utterance in two voices: one female, one male, rotating accents.
    for i, u in enumerate(UTTERANCES):
        for vk in (VOICES[i % 6][0], VOICES[(i + 3) % 6][0]):
            samples, pauses = render(u, vk)
            path = f"audio/synthetic/{u['id']}__{vk}.wav"
            write_wav(path, add_noise(samples, seed=zlib.crc32(f"{u['id']}{vk}".encode())))
            entries.append(dict(id=f"{u['id']}__{vk}", file=path, source="synthetic",
                                duration_s=round(len(samples) / SR, 3), pauses=pauses, typing=False,
                                license="generated locally with macOS say (Apple system voices)",
                                **voice_meta(vk), **gts[u["id"]]))
            print(entries[-1]["id"], entries[-1]["duration_s"], [(p["start_s"], p["dur_s"]) for p in pauses])

    # Typing mid-speech: pause items again with key clicks inside every pause.
    for i, u in enumerate(x for x in UTTERANCES if x["category"] == "pause"):
        vk = VOICES[(i + 1) % 6][0]
        samples, pauses = render(u, vk)
        mixed = mix_typing(samples, [(p["start_s"], p["end_s"]) for p in pauses], seed=i)
        path = f"audio/typing/{u['id']}__{vk}__typing.wav"
        write_wav(path, add_noise(mixed, seed=1000 + i))
        g = dict(gts[u["id"]]); g["category"] = "typing"; g["tags"] = g["tags"] + ["pause"]
        entries.append(dict(id=f"{u['id']}__{vk}__typing", file=path, source="synthetic",
                            duration_s=round(len(mixed) / SR, 3), pauses=pauses, typing=True,
                            license="generated locally with macOS say (Apple system voices)",
                            **voice_meta(vk), **g))

    # Long-form: 5 sessions, one voice each, 12 utterances, 0.4-3 s gaps.
    order = [u for u in UTTERANCES]
    rng.shuffle(order)
    for k in range(5):
        vk = LONGFORM_VOICES[k]
        group = order[k * 12:(k + 1) * 12]
        audio = array.array("h")
        segs, pauses, names, names_v = [], [], [], []
        ref_c, ref_v = "", ""
        tok_c = tok_v = 0
        for j, u in enumerate(group):
            if j:
                gap = round(rng.uniform(0.4, 3.0), 2)
                audio += silence(gap * 1000)
                segs.append({"type": "gap", "start_s": round(len(audio) / SR - gap, 3), "dur_s": gap})
            samples, ps = render(u, vk)
            t0 = len(audio) / SR
            audio += samples
            g = gts[u["id"]]
            sep_c = " " if ref_c else ""; sep_v = " " if ref_v else ""
            for s in g["names"]:
                names.append(dict(s, start=s["start"] + len(ref_c) + len(sep_c), end=s["end"] + len(ref_c) + len(sep_c)))
            for s in g["names_verbatim"]:
                names_v.append(dict(s, start=s["start"] + len(ref_v) + len(sep_v), end=s["end"] + len(ref_v) + len(sep_v)))
            for p in ps:
                pauses.append(dict(p, start_s=round(p["start_s"] + t0, 3), end_s=round(p["end_s"] + t0, 3),
                                   after_token=p["after_token"] + tok_c, after_token_verbatim=p["after_token"] + tok_v,
                                   utterance_id=u["id"]))
            segs.append({"type": "utterance", "utterance_id": u["id"], "start_s": round(t0, 3),
                         "end_s": round(len(audio) / SR, 3)})
            ref_c += sep_c + g["reference_clean"]; ref_v += sep_v + g["reference_verbatim"]
            tok_c += len(g["reference_clean"].split()); tok_v += len(g["reference_verbatim"].split())
        path = f"audio/longform/long{k + 1}__{vk}.wav"
        write_wav(path, add_noise(audio, seed=5000 + k))
        entries.append(dict(id=f"long{k + 1}__{vk}", file=path, source="synthetic", category="longform",
                            tags=["longform"], duration_s=round(len(audio) / SR, 3), typing=False,
                            license="generated locally with macOS say (Apple system voices)",
                            **voice_meta(vk), utterance_id=None, reference_verbatim=ref_v, reference_clean=ref_c,
                            names=names, names_verbatim=names_v,
                            terms=[t for u in group for t in gts[u["id"]]["terms"]],
                            pauses=pauses, segments=segs))
        print(entries[-1]["id"], entries[-1]["duration_s"], "s,", len(pauses), "pauses")

    with open("manifest.synthetic.json", "w") as f:
        json.dump(entries, f, indent=2)
    merge()


def merge():
    os.chdir(HERE)
    entries = json.load(open("manifest.synthetic.json"))
    if os.path.exists("manifest.human.json"):
        entries += json.load(open("manifest.human.json"))
    with open("manifest.json", "w") as f:
        json.dump({"sample_rate": SR, "format": "WAV PCM 16-bit mono",
                   "fields": {
                       "reference_verbatim": "everything said, fillers and abandoned words included",
                       "reference_clean": "what the speaker meant (self-corrections resolved, fillers gone)",
                       "names": "spans in reference_clean; names_verbatim spans in reference_verbatim",
                       "terms": "code-ish terms with their ideal written form",
                       "pauses": "mid-sentence pauses (kind=mid) and trailing-off silences (kind=trailing); after_token indexes reference_clean.split()",
                   },
                   "items": entries}, f, indent=2)
    print("manifest.json:", len(entries), "items")


if __name__ == "__main__":
    if sys.argv[1:] == ["merge"]:
        merge()
    else:
        main()
