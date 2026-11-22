#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "$#" -eq 0 ]; then set -- dev; fi
MODE="${1:-}"
HAS_ONLY=0
for arg in "$@"; do
  [ "$arg" = --only ] && HAS_ONLY=1
done
if [[ "$MODE" =~ ^(all|dev|holdout)$ ]] && [ "$HAS_ONLY" -eq 0 ] && [ -z "${CODENV_HEAVY_HELD:-}" ]; then
  if command -v heavy-lock >/dev/null 2>&1; then
    exec heavy-lock --label "exam $* " -- env CODENV_HEAVY_HELD=1 "$ROOT/scripts/exam.sh" "$@"
  fi
fi

exec "$ROOT/scripts/exam/prefs-sweep" -- node "$ROOT/scripts/exam/run.mjs" "$@"
