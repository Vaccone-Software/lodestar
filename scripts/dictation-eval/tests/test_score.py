import json, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import score  # noqa: E402

ITEMS = {i["id"]: i for i in json.load(open(os.path.join(ROOT, "manifest.json")))["items"]}


def one(item_id, hyp):
    return score.score_item(ITEMS[item_id], hyp)


def break_at_pauses(item, sep=". ", cap=True):
    """Reference text with a sentence break inserted at every mid pause."""
    toks = item["reference_clean"].split()
    for p in sorted((p for p in item["pauses"] if p["kind"] == "mid"), key=lambda p: -p["after_token"]):
        k = p["after_token"]
        toks[k] = toks[k] + sep.strip()
        if cap:
            toks[k + 1] = toks[k + 1][:1].upper() + toks[k + 1][1:]
    return " ".join(toks)


class Normalize(unittest.TestCase):
    def n(self, s):
        return [t for t, _ in score.normalize(s)]

    def test_identifiers_and_numbers(self):
        self.assertEqual(self.n("DraftController.swift"), self.n("draft controller dot swift"))
        self.assertEqual(self.n("local/dev"), self.n("local slash dev"))
        self.assertEqual(self.n("0.39.6"), self.n("zero point thirty-nine point six"))
        self.assertEqual(self.n("October 14th at 2 PM"), self.n("october fourteenth at two p.m."))
        self.assertEqual(self.n("the U A T build"), self.n("the UAT build"))
        self.assertEqual(self.n("port 3000"), self.n("port three thousand"))

    def test_fillers_and_punctuation(self):
        self.assertEqual(self.n("Um, can you, uh, open... the file?"), ["can", "you", "open", "the", "file"])
        self.assertIn("um", [t for t, _ in score.normalize("Um, yes", drop_fillers=False)])


P01 = next(k for k in ITEMS if k.startswith("p01__"))


class Items(unittest.TestCase):
    def test_perfect_clean_and_verbatim(self):
        for iid, it in ITEMS.items():
            r = score.score_item(it, it["reference_clean"])
            self.assertEqual(r["wer_clean_err"], 0, iid)
            self.assertEqual(r["names_exact"], r["names_n"], iid)
            self.assertEqual(r["terms_exact"], r["terms_n"], iid)
            self.assertEqual(r["pauses"]["break"], 0, iid)
            self.assertEqual(r["pauses"]["unaligned"], 0, iid)
            self.assertEqual(r["ellipses"], 0, iid)
            v = score.score_item(it, it["reference_verbatim"])
            self.assertEqual(v["wer_err"], 0, iid)
            self.assertEqual(v["wer_strict_err"], 0, iid)

    def test_disfluency_split(self):
        it = "d01__karen"
        r = one(it, "Schedule the UAT review for Tuesday at 10 AM.")
        self.assertEqual(r["wer_clean_err"], 0)
        self.assertGreater(r["wer_err"], 0)          # verbatim had "Monday, no wait, I mean"

    def test_spoken_form_hyp_is_wer_clean_but_misses_terms(self):
        r = one("n01__samantha", "Open draft controller dot swift and find where settle ghost as seen is called, "
                "then tell me why the ghost text in Lodestar sticks around after I paste into Ghostty.")
        self.assertEqual(r["wer_err"], 0)
        self.assertEqual(r["terms_exact"], 0)
        self.assertEqual(r["names_exact"], 2)

    def test_names_exact_vs_loose(self):
        r = one("n01__samantha", "Open draft controller.swift and find where settle ghost a scene is called. "
                "Then tell me why the ghost text in load star sticks around after I paste into ghosty.")
        self.assertEqual((r["names_exact"], r["names_loose"], r["names_n"]), (0, 0, 2))
        self.assertEqual(sorted(r["name_misses"]), ["Ghostty", "Lodestar"])
        it = next(k for k in ITEMS if k.startswith("n17__"))
        r = one(it, ITEMS[it]["reference_clean"].replace("SwiftUI", "Swift UI").replace("MLX", "mlx"))
        self.assertEqual((r["names_exact"], r["names_loose"]), (0, 2))

    def test_pause_break_and_ellipsis(self):
        r = one(P01, "Open DraftController.swift and look at... The function that decides when the panel closes.")
        self.assertEqual(r["pauses"], {"n": 1, "break": 1, "ellipsis": 1, "unaligned": 0})
        self.assertEqual(r["ellipses"], 1)
        self.assertEqual(r["sent_delta"], 1)
        r = one(P01, "Open DraftController.swift and look at. The function that decides when the panel closes.")
        self.assertEqual((r["pauses"]["break"], r["pauses"]["ellipsis"]), (1, 0))
        r = one(P01, "Open DraftController.swift and look at the function that decides when the panel closes.")
        self.assertEqual((r["pauses"]["break"], r["ellipses"]), (0, 0))

    def test_two_pauses(self):
        it = next(k for k in ITEMS if k.startswith("p06__"))
        r = one(it, break_at_pauses(ITEMS[it]))
        self.assertEqual(r["pauses"]["n"], 2)
        self.assertEqual(r["pauses"]["break"], 2)

    def test_trailing_ellipsis(self):
        it = next(k for k in ITEMS if k.startswith("p07__"))
        r = one(it, ITEMS[it]["reference_clean"] + "...")
        self.assertEqual(r["trail_ellipsis"], 1)
        r = one(it, ITEMS[it]["reference_clean"])
        self.assertEqual(r["trail_ellipsis"], 0)

    def test_longform_pause_offsets(self):
        for iid, it in ITEMS.items():
            if it["category"] != "longform" or not any(p["kind"] == "mid" for p in it["pauses"]):
                continue
            r = score.score_item(it, break_at_pauses(it, sep="… ", cap=False))
            n = r["pauses"]["n"]
            self.assertEqual((r["pauses"]["ellipsis"], r["pauses"]["break"], r["pauses"]["unaligned"]), (n, n, 0), iid)

    def test_cli_end_to_end(self):
        hyps = {k: v["reference_clean"] for k, v in ITEMS.items()}
        path = os.path.join(HERE, "_perfect_hyps.json")
        json.dump(hyps, open(path, "w"))
        agg, per = score.main([path, "--json", os.path.join(HERE, "_perfect_scores.json")])
        self.assertEqual(agg["ALL"]["wer_clean"], 0.0)
        self.assertEqual(agg["ALL"]["names_exact"], 1.0)
        self.assertEqual(agg["ALL"]["items"], len(ITEMS))


if __name__ == "__main__":
    unittest.main()
