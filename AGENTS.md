# Lodestar for agents

How an AI agent (or any tool) safely reads and updates a user's Lodestar
configuration. The config is sparse canonical JSON — it holds only what
differs from defaults — and there is a blessed write path.

## The loop

```sh
lodestar schema                    # the full JSON Schema: every option, typed and described
lodestar apps                      # every valid app name for graph entries
lodestar config                    # the effective config (defaults + the user's file)
lodestar config get scroll.speed   # one value, dotted path
lodestar config set scroll.speed 2200   # validated write, applied to the running instance
lodestar config unset scroll.speed # back to the default
lodestar check --json              # full validation: {"ok": bool, "problems": [...]}
```

`config set` validates before writing — a value out of range, an unknown
key, or a broken enum is refused with the problem printed and nothing
written. Successful writes land in the file and reach the running
instance immediately; there is no separate reload step.

Bare words parse as strings (`config set lode.trigger raw-hyper` needs
no quoting); numbers, booleans, and quoted JSON strings read as
themselves.

## Editing the file directly

`~/.config/lodestar/lodestar.json` (path from `lodestar config-path`) may
also be edited as a file: strict JSON, no comments, validated by the
schema at `~/.config/lodestar/lodestar-schema.json` via its `$schema`
key. Keep edits minimal — the file is sparse on purpose, so write only
deviations from defaults; a key equal to its default is noise the next
canonical write will remove. After a direct edit, `lodestar check --json`
then `lodestar reload`.

`check --json` runs the complete validation stack: structural schema
(unknown keys get edit-distance hints), referential checks (graph →
profile registry), and ground truth (declared browser profiles vs. the
browser's real profile list, app names vs. installed apps).

## Diagnostics

```sh
lodestar diagnose           # one paste-able report: version, instance,
                            # accessibility trust, displays, config
                            # validation, state summary, log tail
```

## Driving the running instance

These reach the live app over a Unix socket at
`~/.local/share/lodestar/control.sock` (mode `0600`). They do exactly what
the keys do — same code path, same log lines — and are recorded as route
`other`, so a scripted summon never inflates the numbers the coach reads
to decide which addresses your hands actually use.

```sh
lodestar go g               # summon the chain, or an app by name
lodestar go e p --beside    # a deeper address, arranged beside
lodestar web example.com --profile brave:Xonar
lodestar layout undo        # undo · redo · flip · fill · index <1-9>
lodestar breath gb          # restore; `save`/`delete <address>` too
lodestar state              # the whole world as JSON, parked included
```

Every verb takes `--json` and answers `{"ok": …}`; without it you get one
line. Exit is `0` on success, `1` when the app refused, `69` when nothing
is listening. A chain is tried before an app name, so `go m` is the letter
you bound even on a machine with an app called M.

`state` is the only way to see the **parked** half of the world — the
windows Lodestar is holding as a corner sliver, which no other surface
lists. Breath and layout verbs answer as soon as the work is _accepted_;
the heavy part runs off the keyboard's path by design, so `ok` means begun
rather than finished.

## Notes

- The config carries `version` — the Lodestar release that last wrote
  the file. Never set it yourself; every write stamps it.
- The `gestures` section is one boolean per gesture, named by verb
  (`scroll`, `hints`, `graph`, …); `false` frees that verb's keys to pass
  through to the app. The schema enumerates the valid names.
- Graph keys support multi-letter sugar: `"eo": "Outlook"` binds the
  chain E → O. A multi-letter key is refused (with a problem you'll see
  in `check`) if any prefix of it is already a destination.
- A `lodestar.yaml` may still sit beside the JSON on machines that
  migrated from 0.9.9 or earlier. Nothing reads it any more — the JSON is
  the config, and the stale file is safe to delete.
- State (`state.json`) is machine-owned — never edit it.
