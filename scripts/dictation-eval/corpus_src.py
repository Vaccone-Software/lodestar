"""Ground truth for the synthetic dictation corpus.

Text conventions
- Written form is the ideal text a perfect dictation would paste into Claude
  Code: canonical name casing, code identifiers as written, numerals.
- {pNNNN}    a mid-sentence pause of NNNN ms (the speaker stops, then goes on).
- {trailNNNN} the speaker trails off and stays silent NNNN ms (end of clip).
- Disfluent items give the verbatim text (what was said) and the clean text
  (what the speaker meant). Pause markers only appear in fluent items.
"""

# The user's own list of names the dictionary gets wrong.
USER_NAMES = [
    "Lodestar", "Ghostty", "Xonar", "Kindora", "Vaccone", "Supabase", "Asana",
    "MongoDB Compass", "UAT", "Proton Pass", "Claude Code", "SwiftUI", "MLX",
    "Brex", "Kagi", "Raycast", "AeroSpace", "ZMK", "Kinesis", "Convex", "Expo",
    "Telegram",
]
# Other proper nouns that occur in the text and are tagged too.
EXTRA_NAMES = ["GitHub", "Slack", "TestFlight", "AppleScript", "Maria", "Sam", "San Francisco", "Rocco"]

# Code-ish terms: written form -> how a person says it. Scored as "terms"
# (exact written form in the hypothesis), never expected from raw ASR.
TERMS = {
    "DraftController.swift": "draft controller dot swift",
    "ModelStore.swift": "model store dot swift",
    "settleGhostAsSeen": "settle ghost as seen",
    "markGhostSeen": "mark ghost seen",
    "local/dev": "local slash dev",
    "lodestar.log": "lodestar dot log",
    "scripts/test.sh": "scripts slash test dot S H",
    "swift build": "swift build",
    "0.39.5": "zero point thirty-nine point five",
    "0.39.6": "zero point thirty-nine point six",
    "0.39.7": "zero point thirty-nine point seven",
    "0.40.0": "zero point forty point zero",
}

# Respellings so the synthetic voices say names the way a person would.
# Assumption: Vaccone is said "vah-KOHN" (Americanized), Xonar "ZOH-nar".
PRONUNCIATION = [
    ("MongoDB Compass", "Mongo D B Compass"),
    ("Lodestar's", "Lode star's"),
    ("Lodestar", "Lode star"),
    ("Ghostty", "Ghostee"),
    ("Xonar's", "Zonar's"),
    ("Xonar", "Zonar"),
    ("Kindora", "Kin dora"),
    ("Vaccone", "Vah cone"),
    ("Supabase", "Soopa base"),
    ("SwiftUI", "Swift U I"),
    ("MLX", "M L X"),
    ("ZMK", "Z M K"),
    ("UAT", "U A T"),
    ("AeroSpace", "Aero space"),
    ("Kagi", "Kahgee"),
    ("Raycast", "Ray cast"),
    ("README", "read me"),
    ("DMG", "D M G"),
    ("API", "A P I"),
    ("CLI", "C L I"),
    ("iOS", "eye O S"),
    ("10 AM", "ten A M"),
    ("2 PM", "two P M"),
    ("4 PM", "four P M"),
    ("at 3,", "at three,"),
    ("port 3000", "port three thousand"),
    ("4417", "forty four seventeen"),
    ("200", "two hundred"),
    ("72", "seventy two"),
    ("October 14th", "October fourteenth"),
    ("Mr.", "Mister"),
]


def U(uid, category, text, clean=None, tags=()):
    return {"id": uid, "category": category, "text": text, "clean": clean, "tags": list(tags)}


UTTERANCES = [
    # ---- (a) names: prompts to the coding agent, plus messages -------------
    U("n01", "names", "Open DraftController.swift and find where settleGhostAsSeen is called, then tell me why the ghost text in Lodestar sticks around after I paste into Ghostty.", tags=["agent"]),
    U("n02", "names", "Can you check whether the Supabase migration ran on staging before we send the UAT build to Kindora?", tags=["agent"]),
    U("n03", "names", "Pull the latest from main, rebase local/dev on top of it, and then rebuild the MLX model loader so the editor stops warming on launch.", tags=["agent"]),
    U("n04", "names", "Add a SwiftUI preview for the settings pane that shows the Keyboards page with a Kinesis Advantage and a ZMK board connected.", tags=["agent"]),
    U("n05", "names", "Hey team, the UAT environment for Xonar is back up, so please log your findings in Asana by end of day Thursday.", tags=["message"]),
    U("n06", "names", "Open MongoDB Compass against the staging cluster and tell me how many documents are in the sessions collection.", tags=["agent"]),
    U("n07", "names", "The Raycast extension and Lodestar both grab command space, so make Lodestar back off when Raycast is running.", tags=["agent"]),
    U("n08", "names", "I moved my passwords into Proton Pass, so update the README to say the API key lives there and not in the keychain.", tags=["agent"]),
    U("n09", "names", "Ask Claude Code to write a migration that moves the Convex functions into Supabase edge functions, one table at a time.", tags=["agent"]),
    U("n10", "names", "Bump Lodestar to 0.39.6, update the release notes, and make sure the site fallback points at the new DMG.", tags=["agent", "numbers"]),
    U("n11", "names", "Check whether AeroSpace is fighting Lodestar for window focus when I switch workspaces with the keyboard.", tags=["agent"]),
    U("n12", "names", "Hi Maria, I wanted to follow up on the Brex reimbursement for the Kinesis keyboard, the receipt is attached.", tags=["message", "email"]),
    U("n13", "names", "Search Kagi for the ZMK documentation on hold tap timing and summarize the difference between balanced and tap preferred.", tags=["agent"]),
    U("n14", "names", "Build the Expo app for iOS and send the TestFlight link to the Kindora channel on Telegram.", tags=["agent"]),
    U("n15", "names", "Why does Ghostty drop the first character when the draft panel pastes? Look at the paste path in DraftController.swift.", tags=["agent"]),
    U("n16", "names", "Rocco Vaccone here, I'm out Friday but reachable on Telegram if UAT blows up.", tags=["message"]),
    U("n17", "names", "Write a SwiftUI view that lists every MLX model we have pinned, with its size on disk and the last time it loaded.", tags=["agent"]),
    U("n18", "names", "Move the Xonar onboarding tasks from Asana into the Kindora board and assign them to me.", tags=["agent"]),
    U("n19", "names", "The Convex query is timing out in production, so add logging around the mutation and show me the slowest call from yesterday.", tags=["agent"]),
    U("n20", "names", "Open the Supabase dashboard and check if row level security is on for the invoices table before the UAT demo on October 14th.", tags=["agent", "numbers"]),
    U("n21", "names", "Make the Raycast script call the Lodestar CLI instead of AppleScript, and keep the output under one line.", tags=["agent"]),
    U("n22", "names", "Kill whatever is holding port 3000, restart the Expo dev server, and tail the logs in Ghostty.", tags=["agent", "numbers"]),
    U("n23", "names", "Hi Sam, thanks for the intro to the Xonar team, I'd love to set up a call next Tuesday at 2 PM to walk through the Lodestar demo.", tags=["message", "email", "numbers"]),
    U("n24", "names", "Find every place we call the Brex API and wrap it so a rate limit error retries with backoff.", tags=["agent"]),
    U("n25", "names", "Write a Kagi search bang for the MongoDB Compass docs and add it to my notes.", tags=["agent"]),
    U("n26", "names", "Rename the AeroSpace config key in the README from gaps to outer gaps, and link the AeroSpace docs.", tags=["agent"]),
    U("n27", "names", "Did the ZMK firmware build finish on GitHub? If it did, flash the left half of the Kinesis first.", tags=["agent"]),
    U("n28", "names", "Claude Code keeps reading the whole log file, so tell it to only read the last 200 lines of lodestar.log.", tags=["agent", "numbers"]),
    U("n29", "names", "Store the Kindora staging password in Proton Pass and share it with the rest of the team.", tags=["agent"]),
    U("n30", "names", "Quick update, the Supabase outage is over and the Expo build is green again, so message me on Telegram if you see anything weird.", tags=["message"]),
    U("n31", "names", "Refactor the MLX tokenizer loading out of the editor and into its own file called ModelStore.swift.", tags=["agent"]),
    U("n32", "names", "Open the Asana task for the Xonar UAT sign off and paste the test results from today into the description.", tags=["agent"]),
    U("n33", "names", "When Raycast opens its window, Lodestar should not count that as a focus change, so filter it out in the window model.", tags=["agent"]),
    U("n34", "names", "Compare MongoDB Compass and the Convex dashboard for browsing data and tell me which one Kindora should use.", tags=["agent"]),
    U("n35", "names", "Write a commit message for the Ghostty paste fix, keep it under 72 characters, and don't mention Claude Code.", tags=["agent", "numbers"]),
    U("n36", "names", "Dear Mr. Vaccone, your Brex card ending in 4417 has been approved for the SwiftUI conference in San Francisco.", tags=["message", "email", "numbers"]),
    U("n37", "names", "Check whether AeroSpace and Raycast both register the same hotkey, and if so, move the AeroSpace one to hyper H.", tags=["agent"]),
    U("n38", "names", "Tell me what changed between Lodestar 0.39.5 and 0.39.6 and draft a Telegram message announcing it.", tags=["agent", "numbers"]),
    U("n39", "names", "Set up the Kinesis layout in ZMK so the thumb key sends meh, then test it in Lodestar's key viewer.", tags=["agent"]),
    U("n40", "names", "Ask Claude Code to explain why Xonar's dashboard uses Convex while Kindora uses Supabase.", tags=["agent"]),

    # ---- (b) mid-sentence pauses and trailing off --------------------------
    U("p01", "pause", "Open DraftController.swift and look at {p2000} the function that decides when the panel closes.", tags=["agent"]),
    U("p02", "pause", "I want the Lodestar settings to {p2500} remember which tab was open last time.", tags=["agent"]),
    U("p03", "pause", "Run the tests again but this time {p1800} only the shard that covers the editor.", tags=["agent"]),
    U("p04", "pause", "The problem is that when I stop talking for a second {p2200} the draft adds a period and starts a new sentence.", tags=["agent"]),
    U("p05", "pause", "Tell Claude Code to check the Supabase logs for {p3000} any failed auth calls since Monday.", tags=["agent"]),
    U("p06", "pause", "Can you make the hint labels {p1500} a little bigger and {p2000} use the accent color for the selected one?", tags=["agent"]),
    U("p07", "pause", "We should probably move the Kindora onboarding into Asana and then maybe {trail1800}", tags=["agent", "trailing"]),
    U("p08", "pause", "I think the issue is in how Ghostty handles bracketed paste but {p2000} I'm not totally sure, it could also be the {trail2000}", tags=["agent", "trailing"]),
    U("p09", "pause", "Write a test that types into the panel while {p2000} dictation is still running and check that nothing gets dropped.", tags=["agent"]),
    U("p10", "pause", "Send the Xonar team a message saying the UAT build is ready and {p2800} that the release notes are in the Lodestar repo.", tags=["message"]),

    # ---- (c) disfluencies and self-corrections -----------------------------
    U("d01", "disfluency", "Schedule the UAT review for Monday, no wait, I mean Tuesday, at 10 AM.",
      clean="Schedule the UAT review for Tuesday at 10 AM.", tags=["self-correction", "numbers"]),
    U("d02", "disfluency", "Um, can you open the, uh, the SwiftUI file for the settings pane and add a toggle for sounds?",
      clean="Can you open the SwiftUI file for the settings pane and add a toggle for sounds?", tags=["filler", "repeat"]),
    U("d03", "disfluency", "Push the branch to, scratch that, don't push anything, just commit it to local/dev.",
      clean="Don't push anything, just commit it to local/dev.", tags=["self-correction", "scratch-that"]),
    U("d04", "disfluency", "Use MongoDB Compass to, uh, actually let's use the Convex dashboard instead to look at the users table.",
      clean="Use the Convex dashboard to look at the users table.", tags=["self-correction", "filler"]),
    U("d05", "disfluency", "The meeting with Kindora is at 3, sorry, 4 PM on Thursday.",
      clean="The meeting with Kindora is at 4 PM on Thursday.", tags=["self-correction", "numbers"]),
    U("d06", "disfluency", "So, um, the thing is, uh, Lodestar keeps, keeps losing focus when, um, when Raycast opens.",
      clean="The thing is, Lodestar keeps losing focus when Raycast opens.", tags=["filler", "repeat"]),
    U("d07", "disfluency", "Bump the version to 0.39.7, no, I mean 0.40.0, because this changes what the app is.",
      clean="Bump the version to 0.40.0 because this changes what the app is.", tags=["self-correction", "numbers"]),
    U("d08", "disfluency", "Send it to the Xonar channel on Slack, or actually Telegram, they don't check Slack.",
      clean="Send it to the Xonar channel on Telegram, they don't check Slack.", tags=["self-correction"]),
    U("d09", "disfluency", "Uh, rename settleGhostAsSeen to, hmm, let me think, markGhostSeen, yeah, markGhostSeen.",
      clean="Rename settleGhostAsSeen to markGhostSeen.", tags=["filler", "self-correction"]),
    U("d10", "disfluency", "Tell Claude Code to delete the old, no, wait, archive the old Brex exports instead of deleting them.",
      clean="Tell Claude Code to archive the old Brex exports instead of deleting them.", tags=["self-correction"]),
]
