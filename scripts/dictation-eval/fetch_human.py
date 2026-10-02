#!/usr/bin/env python3
"""Fetch a small set of REAL human speech clips through the Hugging Face
datasets-server API (no datasets library), convert to 16 kHz mono 16-bit WAV
and write manifest.human.json.

  earnings22 (distil-whisper/earnings22, config chunked, split test)
    earnings calls, accented English, company/product names, natural
    disfluency. License: CC BY-SA 4.0 (Rev.com Earnings-22, del Rio et al. 2022).
  AMI (edinburghcstr/ami, config ihm, split test)
    close-talk headset meeting speech, spontaneous, self-corrections.
    License: CC BY 4.0. Transcripts are upper case with no punctuation.
"""
import json, os, random, re, subprocess, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://datasets-server.huggingface.co/rows?"
FILLERS = re.compile(r"(?i)(?<![\w'])(uh|um|uhm|erm|er|ah|hmm|mm)(?![\w'])[,.]?\s*")
NOT_NAMES = {"I", "I'm", "I've", "I'll", "I'd", "OK", "Okay"}
rng = random.Random(7)


def rows(dataset, config, split, offset, length=100):
    q = urllib.parse.urlencode(dict(dataset=dataset, config=config, split=split, offset=offset, length=length))
    for attempt in range(4):
        try:
            with urllib.request.urlopen(API + q, timeout=60) as r:
                return json.load(r)
        except Exception as e:  # rate limits happen
            print("retry", dataset, offset, e); time.sleep(3 + 3 * attempt)
    raise SystemExit("datasets-server unavailable")


def fetch_audio(url, out):
    tmp = out + ".src"
    for attempt in range(4):
        try:
            urllib.request.urlretrieve(url, tmp); break
        except Exception as e:
            print("retry audio", e); time.sleep(3)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", tmp, out], check=True)
    os.unlink(tmp)
    info = subprocess.run(["afinfo", out], capture_output=True, text=True).stdout
    return float(re.search(r"estimated duration: ([\d.]+)", info).group(1))


def auto_names(text):
    """Capitalized words that do not start a sentence: a rough entity tag."""
    out = []
    for m in re.finditer(r"[A-Z][A-Za-z0-9&'\-]*(?:\s+[A-Z][A-Za-z0-9&'\-]*)*", text):
        word = m.group(0)
        before = text[:m.start()].rstrip()
        if not before or before[-1] in ".?!":
            # sentence-initial: keep only the tail of a multi-word run
            parts = word.split(None, 1)
            if len(parts) < 2:
                continue
            word = parts[1]
            start = m.end() - len(word)
        else:
            start = m.start()
        word = word.rstrip("'")
        if word in NOT_NAMES or not word:
            continue
        name = word[:-2] if word.endswith("'s") else word
        out.append({"name": name, "start": start, "end": start + len(name), "in_user_list": False, "auto": True})
    return out


def pick_earnings(n=30):
    total = rows("distil-whisper/earnings22", "chunked", "test", 0, 1)["num_rows_total"]
    chosen, per_file = [], {}
    offsets = rng.sample(range(0, total - 100, 100), 40)
    for off in offsets:
        if len(chosen) >= n:
            break
        d = rows("distil-whisper/earnings22", "chunked", "test", off)
        cand = []
        for r in d["rows"]:
            row = r["row"]
            t = row["transcription"].strip()
            dur = row["end_ts"] - row["start_ts"]
            words = t.split()
            if "<" in t or not (12 <= len(words) <= 45) or not (4 <= dur <= 18):
                continue
            if per_file.get(row["file_id"], 0) >= 2:
                continue
            score = len(auto_names(t)) * 2 + len(FILLERS.findall(t))
            cand.append((score, r["row_idx"], row))
        cand.sort(key=lambda c: -c[0])
        for score, idx, row in cand[:2]:
            if score == 0 or len(chosen) >= n or per_file.get(row["file_id"], 0) >= 2:
                continue
            per_file[row["file_id"]] = per_file.get(row["file_id"], 0) + 1
            chosen.append((idx, row))
    return chosen


def pick_ami(n=10):
    total = rows("edinburghcstr/ami", "ihm", "test", 0, 1)["num_rows_total"]
    chosen, per_spk = [], {}
    for off in rng.sample(range(0, total - 100, 100), 30):
        if len(chosen) >= n:
            break
        d = rows("edinburghcstr/ami", "ihm", "test", off)
        for r in d["rows"]:
            row = r["row"]
            words = row["text"].split()
            dur = row["end_time"] - row["begin_time"]
            if len(words) < 14 or not (4 <= dur <= 20) or per_spk.get(row["speaker_id"], 0) >= 2:
                continue
            per_spk[row["speaker_id"]] = per_spk.get(row["speaker_id"], 0) + 1
            chosen.append((r["row_idx"], row))
            break
    return chosen


def main():
    os.chdir(HERE)
    os.makedirs("audio/human", exist_ok=True)
    entries = []
    for idx, row in pick_earnings():
        cid = f"h_earn_{row['file_id']}_{row['segment_id']}"
        path = f"audio/human/{cid}.wav"
        dur = fetch_audio(row["audio"][0]["src"], path)
        verbatim = row["transcription"].strip()
        clean = re.sub(r"\s+", " ", FILLERS.sub("", verbatim)).strip()
        clean = clean[:1].upper() + clean[1:]
        entries.append(dict(id=cid, file=path, source="human", category="human", tags=["earnings22", "names-auto"],
                            dataset="distil-whisper/earnings22 (chunked/test)", row_idx=idx,
                            license="CC BY-SA 4.0", voice=f"earnings22:{row['file_id']}", voice_name=None,
                            locale="en (mixed accents)", gender=None, voice_quality="real telephone/webcast audio",
                            duration_s=round(dur, 3), typing=False, utterance_id=None,
                            reference_verbatim=verbatim, reference_clean=clean,
                            names=auto_names(clean), names_verbatim=auto_names(verbatim), terms=[], pauses=[]))
        print(cid, round(dur, 1), verbatim[:80])
    for idx, row in pick_ami():
        cid = f"h_ami_{row['audio_id']}"
        path = f"audio/human/{cid}.wav"
        dur = fetch_audio(row["audio"][0]["src"], path)
        verbatim = row["text"].strip()
        clean = re.sub(r"\s+", " ", FILLERS.sub("", verbatim)).strip()
        entries.append(dict(id=cid, file=path, source="human", category="human", tags=["ami", "spontaneous"],
                            dataset="edinburghcstr/ami (ihm/test)", row_idx=idx, license="CC BY 4.0",
                            voice=f"ami:{row['speaker_id']}", voice_name=None, locale="en (mixed accents)",
                            gender=None, voice_quality="close-talk headset, meeting room",
                            duration_s=round(dur, 3), typing=False, utterance_id=None,
                            reference_verbatim=verbatim, reference_clean=clean,
                            names=[], names_verbatim=[], terms=[], pauses=[]))
        print(cid, round(dur, 1), verbatim[:80])
    with open("manifest.human.json", "w") as f:
        json.dump(entries, f, indent=2)
    print(len(entries), "human clips")


if __name__ == "__main__":
    main()
