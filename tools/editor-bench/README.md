# The editor's accuracy fixture

`build.py` writes `Tests/LodestarCoreTests/Fixtures/editor-accuracy.json`:
sentences written for these tests (no borrowed text), a third left clean,
the rest given one slip of the kind a hand makes, plus slips written by hand
and casual lines that must never be marked. Answers already recorded for an
unchanged sentence are kept.

Each engine's answers are recorded by running the real model:

    LODESTAR_EDITOR_RECORD=standard swift test --filter EditorAccuracyLiveTests
    LODESTAR_EDITOR_RECORD=minimal  swift test --filter EditorAccuracyLiveTests
    LODESTAR_EDITOR_RECORD=full     swift test --filter EditorAccuracyLiveTests

`EditorAccuracyTests` (core, no model) then scores the filter against those
answers on every `swift test`. `LODESTAR_EDITOR_LIVE=<engine>` asks again
without writing — has the model, the prompt, or MLX drifted? — and
`LODESTAR_EDITOR_ONLY=prompt,hand` narrows a live run to a few sources while
trying a prompt. `SHOW_MISSES=1` lists what was missed and what was wrong.

A change to the prompt means recording again: the fixture's answers should
be the ones the shipping prompt gets.
