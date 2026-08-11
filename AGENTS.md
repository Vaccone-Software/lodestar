# Lodestar for agents

How an AI agent (or any tool) safely reads and updates a user's Lodestar
configuration. The contract is four commands and one rule.

## The rule

**Never rewrite the file wholesale.** `~/.config/lodestar/lodestar.yaml` is
hand-edited and heavily commented; Lodestar's own edits are surgical (⌘K in
the searcher adds or removes single graph entries), and yours must be too.
Make surgical edits — add a key, change a value, append a block —
preserving every comment and the existing structure.

## The loop

```sh
lodestar config-path        # where the config lives
lodestar apps               # every valid app name for graph entries
lodestar schema             # the full JSON Schema for the config, on stdout
# … edit the file surgically …
lodestar check --json       # validate: {"ok": bool, "problems": [...]}
lodestar reload             # apply to the running instance (exit 1 + problems if invalid)
```

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

- The config carries `version:` — the Lodestar release that wrote the
  file (e.g. "0.9.5"). Old formats are adapted at load; do not bump the
  version yourself.
- The `gestures:` section is one boolean per gesture, named by verb
  (`scroll`, `hints`, `graph`, …); `false` frees that verb's keys to pass
  through to the app. The schema enumerates the valid names.
- The schema is also on disk at `~/.config/lodestar/lodestar-schema.json`
  with a yaml-language-server modeline on line 1 of the config, so
  editors and LSP-aware tools validate live.
- Graph keys support multi-letter sugar: `eo: Outlook` binds the chain
  E → O. A multi-letter key is refused (with a problem you'll see in
  `check`) if any prefix of it is already a destination.
- State (`state.json`) is machine-owned — never edit it.
