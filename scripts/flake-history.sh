#!/bin/bash
# Which tests fail in CI and which are flaky, over the last runs of ci.yml:
# read-only, through `gh`. See scripts/flake-history.py for what it reads and
# how it decides.
#
#   scripts/flake-history.sh              the last 50 runs
#   scripts/flake-history.sh --runs 100
exec python3 "$(dirname "$0")/flake-history.py" "$@"
