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
# The archive is checked against its SHA-256 and the dataset against its
# two ground-truth files, so a changed or broken download fails here,
# loudly, and CI never runs the replay on half a dataset.
# Tappy (Adams 2017) is larger and optional; its link is left here for
# when the hand-split validation wants it.
set -euo pipefail
ROOT="${LODESTAR_DATASETS:-$HOME/.cache/lodestar-datasets}"
mkdir -p "$ROOT"
cd "$ROOT"
NQ="neuroqwerty-mit-csxpd-dataset-1.0.0"
NQ_SHA256="552f6d6e9ae72bf9f24604c741f148522f776640b90f7b8ac26c51c139c54dda"
whole() { [ -f "$NQ/MIT-CS1PD/GT_DataPD_MIT-CS1PD.csv" ] && [ -f "$NQ/MIT-CS2PD/GT_DataPD_MIT-CS2PD.csv" ]; }
if ! whole; then
    echo "→ fetching neuroQWERTY MIT-CSXPD into $ROOT"
    rm -rf "$NQ"
    curl -fsSL --retry 3 --retry-delay 5 -o nq.zip "https://physionet.org/static/published-projects/nqmitcsxpd/$NQ.zip"
    got=$(shasum -a 256 nq.zip | cut -d' ' -f1)
    if [ "$got" != "$NQ_SHA256" ]; then
        echo "✕ nq.zip is not the published archive (sha256 $got, expected $NQ_SHA256)" >&2
        rm -f nq.zip
        exit 1
    fi
    unzip -q -o nq.zip
    rm -f nq.zip
    whole || { echo "✕ the archive did not hold both ground-truth files" >&2; exit 1; }
fi
echo "✓ $ROOT/$NQ"
echo "  Tappy (optional): https://physionet.org/content/tappy/1.0.0/"
echo "  run: LODESTAR_DATASETS=$ROOT swift test --filter ReplayTests"
