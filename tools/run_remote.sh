#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:?need OUT_DIR}"
SEED="${2:-123}"

mkdir -p "$OUT_DIR"
python3 -m src.solution --out "$OUT_DIR" --seed "$SEED"