#!/usr/bin/env python3
"""The editor's accuracy fixture: sentences written for Lodestar (no
borrowed text), a third left clean, the rest given one slip of the kind a
hand makes, plus slips written by hand. The model's answers are recorded
into the fixture by an env-gated test (see README.md); the core test then
scores the filter against those answers on every run.

    python3 tools/editor-bench/build.py   # rewrites the fixture's cases, keeps recorded answers
"""
import json, os, random, re

random.seed(2026)
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "../../Tests/LodestarCoreTests/Fixtures/editor-accuracy.json")

CHAT = """yeah that works for me, ping me when it's deployed
ok so the tap died again, looking now
can you take a look at the PR when you get a chance?
I think we should ship this on Monday instead of Friday.
np, I'll handle the release notes tonight
The dashboard numbers look off since the migration last week.
Let me know if you're free for a quick call after lunch.
I pushed a fix, but the tests are still flaky on CI.
running a few minutes late, start without me
did anyone else get logged out this morning?
the build is green again, thanks for jumping on it
I'll be out tomorrow afternoon for a dentist appointment.
can we move standup to ten on Thursday?
the new onboarding flow feels much faster to me
I left a few comments on the design doc, nothing blocking.
we should probably write this down before we forget why
their team is waiting on our answer before they start
it's fine for now, but we need a real fix before the launch
does anyone know where the staging credentials live now?
I merged the branch and deleted the old one.
honestly the simpler version reads better
give me ten minutes and I'll send you the numbers
the meeting ran long so I missed your message, sorry
I tested it on my laptop and it works as expected.
we can revisit the pricing question next quarter
lunch is here if anyone wants some
the invoice went out yesterday, so we should hear back soon
I rewrote the intro but kept your examples.
thanks for the quick turnaround on this
let's keep the scope small and see how people use it
the printer on the third floor is broken again
I'm going to take the rest of the day off, feeling sick
the logs say the request timed out after thirty seconds
could you double check the date on the second slide?
I booked the room for two hours just in case
we never heard back from the vendor about the contract
the fix is small but the test coverage is the real work
I'll share my screen so we can walk through it together
the release is tagged, notes are going out in an hour
it looks like the cache was holding onto an old version""".splitlines()

EMAIL = """Thank you for sending the proposal over so quickly.
I have attached the signed agreement to this message.
Please let me know if the revised timeline works for your team.
We would be happy to schedule a follow-up call next week.
I wanted to check whether you had a chance to review the draft.
The shipment is expected to arrive by the end of the month.
Our office will be closed on Monday for the holiday.
I appreciate your patience while we sort out the billing issue.
Could you confirm the address we should use for the delivery?
The workshop will begin at nine and finish before lunch.
I am writing to follow up on our conversation from Tuesday.
We have updated the policy to reflect the new requirements.
Please find the meeting notes and action items below.
I will be traveling next week, so replies may be slower than usual.
The candidate has accepted the offer and will start in two weeks.
We noticed a small error in the last invoice and have corrected it.
If you have any questions, please do not hesitate to reach out.
The board approved the budget at yesterday's meeting.
I would like to introduce you to a colleague who works on the same problem.
Thank you again for taking the time to meet with us.
The report covers the three months ending in September.
Our team has reviewed the feedback and made the requested changes.
I have copied my manager so she can follow the discussion.
The session was recorded, and the link will be shared tomorrow.
We are still waiting for the final numbers from the finance team.""".splitlines()

TEXTS = """on my way, be there in ten
did you remember to feed the cat?
the movie starts at eight so let's grab food before
I found your keys in the car
happy birthday!! hope you have the best day
we're out of milk and eggs again
can you pick up the kids at four today?
the weather looks nice this weekend, want to go hiking?
I just got home, the traffic was terrible
call me when you get a chance, nothing urgent
dinner at my place on Saturday? bring the dog
I think I left my charger at your apartment
the flight landed early, I'll grab a taxi
that restaurant was so good, we have to go back
my mom says hi and thanks for the flowers
don't forget we have the vet appointment tomorrow
I'm so tired, going to bed early tonight
the package came, it looks great
running to the store, need anything?
we should plan a trip for the spring""".splitlines()

PROMPTS = """Summarize this article in three bullet points for a busy reader.
Write a short email declining the invitation politely.
Explain the difference between a process and a thread with an example.
Rewrite this paragraph so it is easier to read out loud.
List the steps to reset a forgotten password on a Mac.
Give me five ideas for a team lunch that works for vegetarians.
Translate the following sentence into French and keep the tone casual.
Review this function and point out any bugs you see.
Draft a message to the landlord about the broken heater.
What are the tradeoffs between a monorepo and separate repositories?
Help me plan a week of dinners that take less than thirty minutes.
Suggest a clearer name for this variable and explain why.
Turn these meeting notes into a list of action items with owners.
Compare these two job offers and tell me what questions I should ask.
Write a test for the edge case where the list is empty.""".splitlines()

PROSE = """The garden looks different every morning in the early spring.
A good tool disappears into the work it helps you do.
Most of the cost of software is paid after it ships.
The river was higher than anyone could remember.
She kept a notebook by the door for ideas that arrived on walks.
The bakery on the corner opens before the sun comes up.
Small habits compound in ways that are hard to see at first.
The old bridge was closed for repairs through the winter.
He learned to cook by watching his grandmother make soup.
The library added a quiet room for people who work remotely.
Every map leaves something out, and the choice is the point.
The team spent a week measuring before changing a single line.
The city planted trees along the avenue to cool the street.
A clear question is often more useful than a quick answer.
The museum reopened with a new wing for modern art.
Rain moved in from the west just after the game started.
The students built a small robot that could sort recycling.
The coffee shop switched to paper cups last year.
Good documentation answers the question before it is asked.
The train was quiet except for the sound of pages turning.""".splitlines()

# Slips written by hand, with what they should read: the ones a keyboard
# and a hurry make that injection does not.
HAND = [
    ("This is a test message, where I'm happy.", "This is a test message where I'm happy."),
    ("I like This message, haha.", "I like this message, haha."),
    ("I pet a small, cat.", "I pet a small cat."),
    ("I kissed, my beautiful cat.", "I kissed my beautiful cat."),
    ("I should of called you back yesterday.", "I should have called you back yesterday."),
    ("We could of finished this last week.", "We could have finished this last week."),
    ("There's alot of work left on the migration.", "There's a lot of work left on the migration."),
    ("I definately want to be there.", "I definitely want to be there."),
    ("Please keep the two lists seperate.", "Please keep the two lists separate."),
    ("The tests is failing on the main branch.", "The tests are failing on the main branch."),
    ("She have already sent the invoice.", "She has already sent the invoice."),
    ("I going to the store after work.", "I'm going to the store after work."),
    ("Its been a long week for everyone.", "It's been a long week for everyone."),
    ("The team lost it's biggest client.", "The team lost its biggest client."),
    ("Your going to love the new version.", "You're going to love the new version."),
    ("I'd rather walk then drive today.", "I'd rather walk than drive today."),
    ("Don't loose the receipt, we need it.", "Don't lose the receipt, we need it."),
    ("Whose coming to the offsite?", "Who's coming to the offsite?"),
    ("The delay didn't effect the launch date.", "The delay didn't affect the launch date."),
    ("I sent it to to the whole team.", "I sent it to the whole team."),
    ("Can you send me link to the doc?", "Can you send me the link to the doc?"),
    ("We need a update on the budget.", "We need an update on the budget."),
    ("I have went there twice already.", "I have gone there twice already."),
    ("Me and him will handle the setup.", "He and I will handle the setup."),
    ("The data shows that we was right.", "The data shows that we were right."),
    ("I recieved your message this morning.", "I received your message this morning."),
    ("Let me know weather the time works.", "Let me know whether the time works."),
    ("I'm not sure if their ready yet.", "I'm not sure if they're ready yet."),
    ("The meeting is on the the calendar.", "The meeting is on the calendar."),
    ("He don't know about the change yet.", "He doesn't know about the change yet."),
    ("I'll send the file's tomorrow.", "I'll send the files tomorrow."),
    ("We're planning to by new laptops.", "We're planning to buy new laptops."),
    ("The results was better than expected.", "The results were better than expected."),
    ("Thanks, I appreciate you're help.", "Thanks, I appreciate your help."),
    ("I seen the email but haven't replied.", "I saw the email but haven't replied."),
    ("Could you please, review the draft?", "Could you please review the draft?"),
    ("The new policy, applies to everyone.", "The new policy applies to everyone."),
    ("I will call You after the meeting.", "I will call you after the meeting."),
    ("Let's meet at The office tomorrow.", "Let's meet at the office tomorrow."),
    ("It was a honor to work with you.", "It was an honor to work with you."),
]

# Casual writing that must stand exactly as written.
CASUAL_CLEAN = """lol ok np
idk tbh, lmk what you think
gonna ship it rn
sgtm, merging now
ok 🙂 see you then
brb grabbing coffee
yep that's the one
haha no worries
kk, will do
ugh the wifi again""".splitlines()

QWERTY = "qwertyuiop asdfghjkl zxcvbnm".split()
def neighbor(c):
    for row in QWERTY:
        i = row.find(c)
        if i >= 0:
            return random.choice([row[j] for j in (i - 1, i + 1) if 0 <= j < len(row)])
    return c
HOMO = [("their", "there"), ("there", "their"), ("they're", "their"), ("its", "it's"), ("it's", "its"),
        ("your", "you're"), ("you're", "your"), ("then", "than"), ("than", "then"), ("lose", "loose"),
        ("whose", "who's")]
AGREE = [("is", "are"), ("are", "is"), ("was", "were"), ("were", "was"), ("has", "have"), ("have", "has")]
def words(s): return list(re.finditer(r"[A-Za-z']+", s))
def inject(s):
    kinds = ["typo_adjacent", "typo_transpose", "typo_drop", "typo_double", "agreement", "missing_article",
             "duplicate_word"]
    random.shuffle(kinds)
    if any(re.search(r"\b%s\b" % re.escape(a), s) for a, _ in HOMO): kinds.insert(0, "homophone")
    for k in kinds:
        ws = words(s)
        if k.startswith("typo"):
            cands = [m for m in ws if m.group().islower() and len(m.group()) >= 5 and "'" not in m.group()]
            if not cands: continue
            m = random.choice(cands); w = m.group(); i = random.randrange(1, len(w) - 1)
            if k == "typo_adjacent": nw = w[:i] + neighbor(w[i]) + w[i + 1:]
            elif k == "typo_transpose": nw = w[:i] + w[i + 1] + w[i] + w[i + 2:]
            elif k == "typo_drop": nw = w[:i] + w[i + 1:]
            else: nw = w[:i] + w[i] + w[i:]
            if nw == w: continue
            return s[:m.start()] + nw + s[m.end():], k
        if k in ("homophone", "agreement"):
            table = HOMO if k == "homophone" else AGREE
            for a, b in random.sample(table, len(table)):
                m = re.search(r"\b%s\b" % re.escape(a), s)
                if m: return s[:m.start()] + b + s[m.end():], k
            continue
        if k == "missing_article":
            ms = list(re.finditer(r"\b(the|a|an) ", s))
            if not ms: continue
            m = random.choice(ms); return s[:m.start()] + s[m.end():], k
        if k == "duplicate_word":
            cands = [m for m in ws if m.group().lower() in ("the", "to", "a", "and", "of", "in", "is")]
            if not cands: continue
            m = random.choice(cands); return s[:m.end()] + " " + m.group() + s[m.end():], k
    return None

cases = []
pool = [(s, "chat") for s in CHAT] + [(s, "email") for s in EMAIL] + [(s, "text") for s in TEXTS] \
     + [(s, "prompt") for s in PROMPTS] + [(s, "prose") for s in PROSE]
random.shuffle(pool)
for i, (s, src) in enumerate(pool):
    if i % 3 == 0:
        cases.append({"text": s, "want": s, "kind": "clean", "src": src}); continue
    r = inject(s)
    cases.append({"text": r[0], "want": s, "kind": r[1], "src": src} if r else
                 {"text": s, "want": s, "kind": "clean", "src": src})
cases += [{"text": t, "want": w, "kind": "hand", "src": "hand"} for t, w in HAND]
cases += [{"text": s, "want": s, "kind": "clean", "src": "casual"} for s in CASUAL_CLEAN]

# Keep answers already recorded for a case whose text has not changed.
old = {}
if os.path.exists(OUT):
    for c in json.load(open(OUT))["cases"]:
        old[c["text"]] = c.get("answers", {})
for c in cases:
    c["answers"] = old.get(c["text"], {})
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump({"about": "Sentences written for Lodestar's editor tests; answers recorded from each engine. "
                        "Regenerate with tools/editor-bench/build.py.", "cases": cases}, f, indent=1, sort_keys=True,
              ensure_ascii=False)
from collections import Counter
print(len(cases), dict(Counter(c["kind"] for c in cases)))
