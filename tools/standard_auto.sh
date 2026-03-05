#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash tools/standard_auto.sh \
    --spec SPEC.md \
    --remote <ssh-host-alias> \
    --remote-repo-dir <remote-path> \
    --local-log-dir <local-log-path> \
    --conda-path <conda-path>
    --max-iters <num_iters> \

Example:
  bash tools/standard_auto.sh --spec SPEC.md --remote gpu4090d --remote-repo-dir /home/master/code/oymk/TestCodex --local-log-dir /mnt/g/Github/TestCodex/logs --conda-path /home/master/software/oymk/itsamatch --max-iters 5
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

# 本地总控日志：写到 --local-log-dir，避免和远端 run.log 混在一起
mkdir -p "$LOCAL_LOG_DIR/local_master"
MASTER_LOG="$LOCAL_LOG_DIR/local_master/standard_auto_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$MASTER_LOG") 2>&1
echo "[log] local master log: $MASTER_LOG"

# 基本保护：确保在 git repo 里
git rev-parse --is-inside-work-tree >/dev/null

mkdir -p log
mkdir -p logs
grep -qxF "log/" .gitignore 2>/dev/null || echo "log/" >> .gitignore
grep -qxF "logs/" .gitignore 2>/dev/null || echo "logs/" >> .gitignore

# 远端输出不要放 repo 里（避免 git clean -fd 清掉）
REMOTE_OUT_ROOT="/home/master/code/oymk/outputs/$(basename "$ROOT")/runs"

for i in $(seq 1 "$MAX_ITERS"); do
  echo "================ ITER $i/$MAX_ITERS ================"

  # ---- 1) Codex 生成/修改代码（允许 workspace 写；禁用审批避免卡住；不建议 yolo） :contentReference[oaicite:3]{index=3}
  SPEC_TEXT="$(cat "$SPEC")"

  # 先生成本轮 run_ts 与日志目录（便于把本地/远端日志彻底分开存）
  RUN_TS="$(date +%Y%m%d_%H%M%S)"
  RUN_ID="${RUN_TS}_iter${i}"
  LOCAL_LOCAL_DIR="$LOCAL_LOG_DIR/local/$RUN_ID"
  LOCAL_REMOTE_DIR="$LOCAL_LOG_DIR/remote/$RUN_ID"
  mkdir -p "$LOCAL_LOCAL_DIR" "$LOCAL_REMOTE_DIR"
  cp -a "$SPEC" "$LOCAL_LOCAL_DIR/SPEC.md" 2>/dev/null || true

  CODEX_OUT="$LOCAL_LOCAL_DIR/codex_iter.txt"
  codex exec \
    --sandbox workspace-write \
    "$SPEC_TEXT
额外约束：
- 你只能改工作区代码（.py、tests 等），不要做 git push/ssh/scp（这些由外层脚本做）。
" 2>&1 | tee "$CODEX_OUT"


  # ---- 3) 自动提交（可选 push）
  git add -A
  if git diff --cached --quiet; then
    echo "[warn] no changes to commit (Codex may have made no edits)."
  else
    git commit -m "codex autopilot iter $i"
    if [[ "${STANDARD_AUTO_PUSH:-0}" == "1" ]]; then
      git push
    else
      echo "[info] STANDARD_AUTO_PUSH!=1, skip git push."
    fi
  fi

  # commit 可能变化：用最新 commit 生成最终 run_id，并把日志目录按最终 run_id 归档
  COMMIT="$(git rev-parse --short HEAD)"
  FINAL_RUN_ID="${RUN_TS}_${COMMIT}_iter${i}"
  if [[ "$FINAL_RUN_ID" != "$RUN_ID" ]]; then
    FINAL_LOCAL_LOCAL_DIR="$LOCAL_LOG_DIR/local/$FINAL_RUN_ID"
    FINAL_LOCAL_REMOTE_DIR="$LOCAL_LOG_DIR/remote/$FINAL_RUN_ID"
    mv "$LOCAL_LOCAL_DIR" "$FINAL_LOCAL_LOCAL_DIR"
    mv "$LOCAL_REMOTE_DIR" "$FINAL_LOCAL_REMOTE_DIR"
    RUN_ID="$FINAL_RUN_ID"
    LOCAL_LOCAL_DIR="$FINAL_LOCAL_LOCAL_DIR"
    LOCAL_REMOTE_DIR="$FINAL_LOCAL_REMOTE_DIR"
  fi

  # ---- 4) 远端运行
  # NOTE: 不依赖远端访问 GitHub（避免 HTTPS/TLS 失败）；直接把当前工作区打包同步到远端。
  REMOTE_OUT_DIR="${REMOTE_OUT_ROOT}/${RUN_ID}"
  echo "[remote] syncing workspace to $REMOTE:$REMOTE_REPO_DIR (excluding .git/log/logs)"

  # 清理远端工作区
  ssh "$REMOTE" "set -euo pipefail; mkdir -p \"$REMOTE_REPO_DIR\"; find \"$REMOTE_REPO_DIR\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +"

  # 传输工作区（tar over ssh，避免远端 git clone/fetch）
  tar -C "$ROOT" \
    --exclude=.git \
    --exclude=log \
    --exclude=logs \
    -czf - . \
    | ssh "$REMOTE" "set -euo pipefail; mkdir -p \"$REMOTE_REPO_DIR\"; tar -xzf - -C \"$REMOTE_REPO_DIR\""

  # 运行远端任务（把 ssh 输出落到本地 remote/ 目录，避免混进本地 master log）
  REMOTE_SSH_LOG="$LOCAL_REMOTE_DIR/ssh.log"
  ssh "$REMOTE" "set -euo pipefail;
    cd \"$REMOTE_REPO_DIR\";
    mkdir -p \"$REMOTE_OUT_DIR\";

    export PATH=\"$CONDA_DIR/bin:\$PATH\";
    hash -r;
    python -V;

    bash tools/run_remote.sh \"$REMOTE_OUT_DIR\" 123 2>&1 | tee \"$REMOTE_OUT_DIR/run.log\";
  " >"$REMOTE_SSH_LOG" 2>&1

  # 拉回远端产物到你指定的本地 logs 目录（remote/ 子目录）
  scp -r "$REMOTE:$REMOTE_OUT_DIR" "$LOCAL_REMOTE_DIR/"

  # 同时复制一份到 repo 内，方便下一轮 Codex 读取（sandbox workspace-write 默认只看工作区）:contentReference[oaicite:4]{index=4}
  rm -rf log/last_run 2>/dev/null || true
  mkdir -p log/last_run
  cp -a "$LOCAL_REMOTE_DIR/$(basename "$REMOTE_OUT_DIR")"/* log/last_run/ || true


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
  " 2>&1 | tee "$LOCAL_LOCAL_DIR/codex_judge.txt"

  # 把 decision 也落盘到本地 local/ 目录，便于离线查看
  cp -a "$DECISION_FILE" "$LOCAL_LOCAL_DIR/decision.json" 2>/dev/null || true
  # 同步一份远端关键产物到本地 local/（只拷 metrics.json/run.log，方便查看）
  cp -a log/last_run/metrics.json "$LOCAL_LOCAL_DIR/metrics.json" 2>/dev/null || true
  cp -a log/last_run/run.log "$LOCAL_LOCAL_DIR/run.log" 2>/dev/null || true

  if grep -q '"pass":[[:space:]]*true' "$DECISION_FILE"; then
    echo "[done] Codex 判定达标，停止。decision=$DECISION_FILE"
    echo "[logs] local:  $LOCAL_LOCAL_DIR"
    echo "[logs] remote: $LOCAL_REMOTE_DIR/$(basename "$REMOTE_OUT_DIR")"
    exit 0
  fi
done

exit 1