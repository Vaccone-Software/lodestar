#!/bin/bash
# The public keystroke datasets the replay tests validate against. Nothing
# here ships in Lodestar or lands in anyone's data directory: the tests
# read them from $LODESTAR_DATASETS and skip when it is unset.
#
#   ./tools/health/fetch-datasets.sh            # into ~/.cache/lodestar-datasets
#   LODESTAR_DATASETS=/somewhere ./tools/health/fetch-datasets.sh
#   LODESTAR_DATASETS=~/.cache/lodestar-datasets swift test --filter ReplayTests
#
# neuroQWERTY MIT-CSXPD (Giancardo et al. 2016), PhysioNet, 7.3 MB:
# 85 subjects, key / hold / release / press per row, PD status per subject.
# Tappy (Adams 2017) is larger and optional; its link is left here for
# when the hand-split validation wants it.
set -euo pipefail
ROOT="${LODESTAR_DATASETS:-$HOME/.cache/lodestar-datasets}"
mkdir -p "$ROOT"
cd "$ROOT"
NQ="neuroqwerty-mit-csxpd-dataset-1.0.0"
if [ ! -d "$NQ" ]; then
    echo "→ fetching neuroQWERTY MIT-CSXPD into $ROOT"
    curl -fsSL -o nq.zip "https://physionet.org/static/published-projects/nqmitcsxpd/$NQ.zip"
    unzip -q -o nq.zip
    rm -f nq.zip
fi
echo "✓ $ROOT/$NQ"
echo "  Tappy (optional): https://physionet.org/content/tappy/1.0.0/"
echo "  run: LODESTAR_DATASETS=$ROOT swift test --filter ReplayTests"
