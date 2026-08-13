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

## Notes

- The config carries `version` — the Lodestar release that last wrote
  the file. Never set it yourself; every write stamps it.
- The `gestures` section is one boolean per gesture, named by verb
  (`scroll`, `hints`, `graph`, …); `false` frees that verb's keys to pass
  through to the app. The schema enumerates the valid names.
- Graph keys support multi-letter sugar: `"eo": "Outlook"` binds the
  chain E → O. A multi-letter key is refused (with a problem you'll see
  in `check`) if any prefix of it is already a destination.
- A `lodestar.yaml` may sit beside the JSON on machines that migrated
  from 0.9.9 or earlier. It is inert — never edit it; the JSON is the
  config.
- State (`state.json`) is machine-owned — never edit it.
