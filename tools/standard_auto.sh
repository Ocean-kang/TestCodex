#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash tools/standard_codex.sh \
    --spec SPEC.md \
    --remote <ssh-host-alias> \
    --remote-repo-dir <remote-path> \
    --local-log-dir <local-log-path> \
    --conda-path <conda-path>
    --max-iters <num_iters> \

Example:
  bash tools/standard_codex.sh --spec SPEC.md --remote gpu4090d --remote-repo-dir /home/master/code/TestCodex --local-log-dir /mnt/g/Github/TestCodex/logs --conda-path /home/master/software/oymk/uvlt --max-iters 5
USAGE
}

SPEC=""
REMOTE=""
REMOTE_REPO_DIR=""
LOCAL_LOG_DIR=""
CONDA_DIR=""
MAX_ITERS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    --remote-repo-dir) REMOTE_REPO_DIR="$2"; shift 2;;
    --local-log-dir) LOCAL_LOG_DIR="$2"; shift 2;;
    --conda-path) CONDA_DIR="$2"; shift 2;;
    --max-iters) MAX_ITERS="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$SPEC" || -z "$REMOTE" || -z "$REMOTE_REPO_DIR" || -z "$LOCAL_LOG_DIR" || -z "$CONDA_DIR" ]]; then
  echo "Missing required args." >&2
  usage
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 基本保护：确保在 git repo 里
git rev-parse --is-inside-work-tree >/dev/null

mkdir -p log
grep -qxF "log/" .gitignore 2>/dev/null || echo "log/" >> .gitignore

# 远端输出不要放 repo 里（避免 git clean -fd 清掉）
REMOTE_OUT_ROOT="/home/master/code/oymk/outputs/$(basename "$ROOT")/runs"

for i in $(seq 1 "$MAX_ITERS"); do
  echo "================ ITER $i/$MAX_ITERS ================"

  # ---- 1) Codex 生成/修改代码（允许 workspace 写；禁用审批避免卡住；不建议 yolo） :contentReference[oaicite:3]{index=3}
  SPEC_TEXT="$(cat "$SPEC")"
  CODEX_OUT="log/codex_iter_${i}.txt"

  codex exec \
    --sandbox workspace-write \
    "$SPEC_TEXT
额外约束：
- 你只能改工作区代码（.py、tests 等），不要做 git push/ssh/scp（这些由外层脚本做）。
" 2>&1 | tee "$CODEX_OUT"


  # ---- 3) 自动提交并 push
  git add -A
  if git diff --cached --quiet; then
    echo "[warn] no changes to commit (Codex may have made no edits)."
  else
    git commit -m "codex autopilot iter $i"
    git push
  fi

  COMMIT="$(git rev-parse --short HEAD)"
  RUN_ID="$(date +%Y%m%d_%H%M%S)_${COMMIT}_iter${i}"
  REMOTE_OUT_DIR="${REMOTE_OUT_ROOT}/${RUN_ID}"
  LOCAL_RUN_DIR="${LOCAL_LOG_DIR}/${RUN_ID}"

  REMOTE_URL="$(git config --get remote.origin.url || true)"
if [[ -z "$REMOTE_URL" ]]; then
  echo "ERROR: current repo has no remote.origin.url" >&2
  exit 3
fi

ssh "$REMOTE" "set -euo pipefail;
  if [ ! -d \"$REMOTE_REPO_DIR/.git\" ]; then
    mkdir -p \"$(dirname "$REMOTE_REPO_DIR")\";
    git clone \"$REMOTE_URL\" \"$REMOTE_REPO_DIR\";
  fi

  cd \"$REMOTE_REPO_DIR\";
  git fetch origin;
  git reset --hard origin/main;
  git clean -fd;

  mkdir -p \"$REMOTE_OUT_DIR\";

  # --- use conda env by prefix path (your --conda-path) ---
  export PATH=\"$CONDA_DIR/bin:\$PATH\";
  hash -r;
  python -V;

  bash tools/run_remote.sh \"$REMOTE_OUT_DIR\" 123 2>&1 | tee \"$REMOTE_OUT_DIR/run.log\";
"

  # ---- 4) 拉回远端产物到你指定的本地 logs 目录
  mkdir -p "$LOCAL_RUN_DIR"
  scp -r "$REMOTE:$REMOTE_OUT_DIR" "$LOCAL_RUN_DIR/"

  # 同时复制一份到 repo 内，方便下一轮 Codex 读取（sandbox workspace-write 默认只看工作区）:contentReference[oaicite:4]{index=4}
  rm -rf log/last_run
  mkdir -p log/last_run
  cp -a "$LOCAL_RUN_DIR/$(basename "$REMOTE_OUT_DIR")"/* log/last_run/ || true


  # ---- 5)
  DECISION_FILE="log/decision.json"
  rm -f "$DECISION_FILE"

  codex exec \
    --sandbox workspace-write \
    "请阅读 log/last_run/metrics.json 和 log/last_run/run.log（如存在）。
  根据 SPEC 的验收标准判断本轮远端运行是否达标：
  - 若已达标：不要修改任何代码；写出 $DECISION_FILE 内容为 {\"pass\": true, \"reason\": \"...\"}
  - 若未达标：请直接修改代码/测试以提高指标；同时写出 $DECISION_FILE 内容为 {\"pass\": false, \"reason\": \"...\"}
  要求：无论如何都必须写出 $DECISION_FILE。
  " 2>&1 | tee "log/codex_judge_${i}.txt"

  if grep -q '"pass":[[:space:]]*true' "$DECISION_FILE"; then
    echo "[done] Codex 判定达标，停止。decision=$DECISION_FILE"
    exit 0
  fi
done

exit 1