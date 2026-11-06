#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "$#" -eq 0 ]; then set -- dev; fi
exec node "$ROOT/scripts/exam/run.mjs" "$@"
