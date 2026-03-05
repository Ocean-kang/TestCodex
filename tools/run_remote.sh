#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:?need OUT_DIR}"
SEED="${2:-123}"

mkdir -p "$OUT_DIR"
# python3 -m src.projector --out "$OUT_DIR" --seed "$SEED"

python -V
python - <<'PY'
import torch
print("torch", torch.__version__)
print("cuda available:", torch.cuda.is_available())
PY

# 再跑你的 CLI 产物
python -m src.projector --out "$OUT_DIR" --seed "$SEED"

# 把关键文件打印一下，保证 run.log 永远不为空
echo "=== metrics.json ==="
cat "$OUT_DIR/metrics.json"