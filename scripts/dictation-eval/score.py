#!/usr/bin/env python3
"""Score dictation hypotheses against manifest.json.

  python3 score.py hyps.json [--manifest manifest.json] [--json out.json] [--items]

hyps.json is {item_id: hypothesis_text}. Items without a hypothesis are skipped
(and counted). Metrics, per item and aggregated overall / by category / voice:

  wer          verbatim reference, fillers (um, uh, ...) dropped on both sides:
               the recognition error rate
  wer_strict   verbatim reference with fillers kept (rewards transcribing them)
  wer_clean    clean (intended) reference, fillers dropped: distance from what
               the speaker meant; the target for an editor pass
  names        exact-case match of each tagged name (count-aware);
               names_loose ignores case and spaces/hyphens/dots inside the name
               ("Swift UI", "mongodb compass" count as loose hits)
  terms        exact written form of code-ish terms (DraftController.swift ...)
  pauses       at each mid-sentence pause: spurious sentence break (terminal
               punctuation before the next word, or that word capitalized when
               the reference has it lower case) and ellipsis at the pause
  ellipses     "..." or "…" in the hypothesis beyond those in the reference
               (synthetic references have none)
  trail_ellipsis  hypothesis of a trailing-off item ends in an ellipsis
  sent_delta   sentences in hypothesis minus sentences in reference_clean

Normalization for WER: lowercase, punctuation stripped, camelCase and
dotted/slashed identifiers split into words ("DraftController.swift" ->
"draft controller dot swift", "local/dev" -> "local slash dev"), runs of single
capital letters joined ("U A T" -> "uat"), number words to digits
("zero point thirty-nine point six" -> "0.39.6", "fourteenth" -> "14").
"""
import argparse, difflib, json, os, re, sys
from collections import defaultdict

FILLERS = {"um", "uh", "uhm", "umm", "erm", "er", "ah", "hmm", "mm", "mhm", "eh"}
UNITS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve "
                                     "thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split())}
TENS = {w: 10 * (i + 2) for i, w in enumerate("twenty thirty forty fifty sixty seventy eighty ninety".split())}
ORD = {"first": "one", "second": "two", "third": "three", "fourth": "four", "fifth": "five", "sixth": "six",
       "seventh": "seven", "eighth": "eight", "ninth": "nine", "tenth": "ten", "eleventh": "eleven",
       "twelfth": "twelve", "thirteenth": "thirteen", "fourteenth": "fourteen", "fifteenth": "fifteen",
       "sixteenth": "sixteen", "seventeenth": "seventeen", "eighteenth": "eighteen", "nineteenth": "nineteen",
       "twentieth": "twenty", "thirtieth": "thirty"}
# "second" is far more often the unit of time than an ordinal: leave it.
ORD.pop("second")
ELLIPSIS = re.compile(r"\.\.\.|…")
SENT_END = re.compile(r"[.!?…]['\")\]]*$")


# ------------------------------------------------------------ normalize ----
def _split_raw(token):
    """One whitespace token -> list of word pieces, case preserved."""
    s = token.replace("’", "'").replace("‘", "'")
    s = ELLIPSIS.sub(" ", s)
    s = re.sub(r"\b([ap])\.m\.", r"\1m", s, flags=re.I)
    s = re.sub(r"\b((?:[A-Za-z]\.){2,})", lambda m: m.group(1).replace(".", ""), s)   # U.A.T. -> UAT
    s = re.sub(r"(?<=[A-Za-z])\.(?=[A-Za-z])", " dot ", s)                              # file.swift
    s = re.sub(r"(?<=\w)/(?=\w)", " slash ", s)
    s = re.sub(r"(?<=\w)_(?=\w)", " underscore ", s)
    s = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", s)
    s = re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", s)                 # camelCase
    s = re.sub(r"(?<=\d)(?=[A-Za-z])|(?<=[A-Za-z])(?=\d)", " ", s)                       # 10AM
    s = s.replace("&", " and ").replace("%", " percent ").replace("-", " ").replace("—", " ").replace("–", " ")
    s = re.sub(r"(?<!\d)\.|\.(?!\d)", " ", s)                                           # periods, keep 0.39
    s = re.sub(r"[^\w.' ]", " ", s)
    s = re.sub(r"(?<![a-zA-Z])'|'(?![a-zA-Z])", " ", s)
    return s.split()


def _numbers(toks):
    """toks: list of (word, owner). Number words -> digits, 'X point Y' -> 'X.Y'."""
    out, i = [], 0
    while i < len(toks):
        if ORD.get(toks[i][0], toks[i][0]) not in UNITS and ORD.get(toks[i][0], toks[i][0]) not in TENS:
            out.append(toks[i]); i += 1
            continue
        total, cur, last, j = 0, 0, None, i
        while j < len(toks):
            x = ORD.get(toks[j][0], toks[j][0])
            if x in UNITS and (last in (None, "hundred", "thousand") or (last == "tens" and UNITS[x] < 10)):
                cur += UNITS[x]; last = "unit"
            elif x in TENS and last in (None, "hundred", "thousand"):
                cur += TENS[x]; last = "tens"
            elif x == "hundred" and last in ("unit", "tens") and cur < 100:
                cur *= 100; last = "hundred"
            elif x == "thousand" and last in ("unit", "tens", "hundred"):
                total += cur * 1000; cur = 0; last = "thousand"
            else:
                break
            j += 1
        out.append((str(total + cur), toks[i][1])); i = j
    # X point Y (point Z)
    merged, i = [], 0
    while i < len(out):
        w, o = out[i]
        if w.replace(".", "").isdigit() and i + 2 < len(out) and out[i + 1][0] == "point" and out[i + 2][0].isdigit():
            s, j = w, i
            while j + 2 < len(out) and out[j + 1][0] == "point" and out[j + 2][0].isdigit():
                s += "." + out[j + 2][0]; j += 2
            merged.append((s, o)); i = j + 1
            continue
        merged.append((w, o)); i += 1
    return merged


def normalize(text, drop_fillers=True):
    """-> list of (normalized token, index of the whitespace token it came from)."""
    raw = ELLIPSIS.sub(lambda m: m.group(0) + " ", text).split()
    pieces = [(p, i) for i, r in enumerate(raw) for p in _split_raw(r)]
    all_caps = text.upper() == text and len(re.findall(r"[A-Za-z]{2,}", text)) >= 4   # AMI-style refs
    if not all_caps:  # join runs of single capitals: U A T -> UAT
        joined = []
        for p, i in pieces:
            if len(p) == 1 and p.isupper() and joined and joined[-1][2]:
                joined[-1] = (joined[-1][0] + p, joined[-1][1], True)
            else:
                joined.append((p, i, len(p) == 1 and p.isupper()))
        pieces = [(p, i) for p, i, _ in joined]
    toks = [(p.lower(), i) for p, i in pieces]
    toks = _numbers(toks)
    if drop_fillers:
        toks = [t for t in toks if t[0] not in FILLERS]
    return toks


def raw_tokens(text):
    return ELLIPSIS.sub(lambda m: m.group(0) + " ", text).split()


# ------------------------------------------------------------- metrics ----
def edit_distance(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def _name_re(name, loose):
    if loose:
        body = r"[\s\-.]?".join(re.escape(c) for c in name.replace(" ", ""))
        return re.compile(r"(?<![A-Za-z0-9])" + body + r"(?![A-Za-z0-9])", re.I)
    return re.compile(r"(?<![A-Za-z0-9])" + re.escape(name) + r"(?![A-Za-z0-9])")


def name_scores(names, hyp):
    want = defaultdict(int)
    for s in names:
        want[s["name"]] += 1
    exact = loose = 0
    misses = []
    for name, n in want.items():
        e = min(n, len(_name_re(name, False).findall(hyp)))
        l = min(n, len(_name_re(name, True).findall(hyp)))
        exact += e; loose += max(l, e)
        if e < n:
            misses.append(name)
    return exact, loose, sum(want.values()), misses


def pause_checks(item, hyp):
    """Spurious sentence breaks / ellipses at each mid-sentence pause."""
    out = {"n": 0, "break": 0, "ellipsis": 0, "unaligned": 0}
    mids = [p for p in item.get("pauses", []) if p.get("kind") == "mid"]
    if not mids:
        return out
    ref_raw = item["reference_clean"].split()
    ref = normalize(item["reference_clean"])
    hyp_raw = raw_tokens(hyp)
    hyp_n = normalize(hyp)
    sm = difflib.SequenceMatcher(None, [t for t, _ in ref], [t for t, _ in hyp_n], autojunk=False)
    ref_to_hyp = {}
    for a, b, size in sm.get_matching_blocks():
        for k in range(size):
            ref_to_hyp[a + k] = b + k
    for p in mids:
        out["n"] += 1
        nxt = p["after_token"] + 1
        pos = next((k for k, (_, o) in enumerate(ref) if o == nxt), None)
        if pos is None or pos not in ref_to_hyp:
            out["unaligned"] += 1
            continue
        h = hyp_n[ref_to_hyp[pos]][1]          # raw hyp token holding the word after the pause
        before = hyp_raw[h - 1] if h > 0 else ""
        word = hyp_raw[h]
        ref_word = ref_raw[nxt] if nxt < len(ref_raw) else ""
        if ELLIPSIS.search(before) or word.startswith(("…", "...")):
            out["ellipsis"] += 1
        if SENT_END.search(before) or (word[:1].isupper() and ref_word[:1].islower()):
            out["break"] += 1
    return out


def sentences(text):
    return len([s for s in re.split(r"(?<=[.!?…])\s+", text.strip()) if re.search(r"\w", s)])


def score_item(item, hyp):
    ref_v = [t for t, _ in normalize(item["reference_verbatim"])]
    ref_vs = [t for t, _ in normalize(item["reference_verbatim"], drop_fillers=False)]
    ref_c = [t for t, _ in normalize(item["reference_clean"])]
    hyp_t = [t for t, _ in normalize(hyp)]
    hyp_ts = [t for t, _ in normalize(hyp, drop_fillers=False)]
    ex, lo, nn, misses = name_scores(item.get("names", []), hyp)
    terms = item.get("terms", [])
    t_hit = sum(1 for t in terms if t["written"] in hyp)
    trailing = any(p.get("kind") == "trailing" for p in item.get("pauses", []))
    return {
        "wer_err": edit_distance(ref_v, hyp_t), "wer_n": len(ref_v),
        "wer_strict_err": edit_distance(ref_vs, hyp_ts), "wer_strict_n": len(ref_vs),
        "wer_clean_err": edit_distance(ref_c, hyp_t), "wer_clean_n": len(ref_c),
        "names_exact": ex, "names_loose": lo, "names_n": nn, "name_misses": misses,
        "terms_exact": t_hit, "terms_n": len(terms),
        "pauses": pause_checks(item, hyp),
        "ellipses": max(0, len(ELLIPSIS.findall(hyp)) - len(ELLIPSIS.findall(item["reference_clean"]))),
        "trail_items": int(trailing),
        "trail_ellipsis": int(trailing and bool(re.search(r"(\.\.\.|…)\W*$", hyp.strip()))),
        "sent_delta": sentences(hyp) - sentences(item["reference_clean"]),
    }


def aggregate(rows):
    a = defaultdict(float)
    for r in rows:
        for k, v in r.items():
            if isinstance(v, (int, float)):
                a[k] += v
        for k, v in r["pauses"].items():
            a["pause_" + k] += v
    def ratio(x, n):
        return round(a[x] / a[n], 4) if a[n] else None
    return {
        "items": len(rows),
        "wer": ratio("wer_err", "wer_n"), "wer_strict": ratio("wer_strict_err", "wer_strict_n"),
        "wer_clean": ratio("wer_clean_err", "wer_clean_n"),
        "names_exact": ratio("names_exact", "names_n"), "names_loose": ratio("names_loose", "names_n"),
        "names_n": int(a["names_n"]),
        "terms_exact": ratio("terms_exact", "terms_n"), "terms_n": int(a["terms_n"]),
        "pause_breaks": f"{int(a['pause_break'])}/{int(a['pause_n'])}",
        "pause_ellipses": f"{int(a['pause_ellipsis'])}/{int(a['pause_n'])}",
        "pause_unaligned": int(a["pause_unaligned"]),
        "ellipses": int(a["ellipses"]),
        "trail_ellipsis": f"{int(a['trail_ellipsis'])}/{int(a['trail_items'])}",
        "mean_sent_delta": round(a["sent_delta"] / len(rows), 3) if rows else None,
    }


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("hyps")
    ap.add_argument("--manifest", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest.json"))
    ap.add_argument("--json", help="write per-item and aggregate results here")
    ap.add_argument("--items", action="store_true", help="print one line per item")
    args = ap.parse_args(argv)
    m = json.load(open(args.manifest))
    items = m["items"] if isinstance(m, dict) else m
    hyps = json.load(open(args.hyps))
    per, groups = {}, defaultdict(list)
    for it in items:
        if it["id"] not in hyps:
            continue
        r = score_item(it, hyps[it["id"]] or "")
        per[it["id"]] = r
        groups["ALL"].append(r)
        groups["source=" + it["source"]].append(r)
        groups["category=" + it["category"]].append(r)
        if it["source"] == "synthetic":
            groups["voice=" + it["voice"]].append(r)
    missing = [it["id"] for it in items if it["id"] not in hyps]
    agg = {k: aggregate(v) for k, v in sorted(groups.items(), key=lambda kv: (kv[0] != "ALL", kv[0]))}
    cols = ["items", "wer", "wer_clean", "wer_strict", "names_exact", "names_loose", "terms_exact",
            "pause_breaks", "pause_ellipses", "ellipses", "trail_ellipsis", "mean_sent_delta"]
    print(f"{'group':24}" + "".join(f"{c:>16}" for c in cols))
    for k, v in agg.items():
        print(f"{k:24}" + "".join(f"{'-' if v[c] is None else v[c]!s:>16}" for c in cols))
    if missing:
        print(f"\n{len(missing)} manifest items had no hypothesis (skipped)")
    if args.items:
        print()
        for k, r in per.items():
            print(f"{k:40} wer {r['wer_err']}/{r['wer_n']}  names {r['names_exact']}/{r['names_n']}"
                  f"  pause-breaks {r['pauses']['break']}/{r['pauses']['n']}  misses {r['name_misses']}")
    if args.json:
        json.dump({"aggregate": agg, "items": per, "missing": missing}, open(args.json, "w"), indent=2)
    return agg, per


if __name__ == "__main__":
    main()
