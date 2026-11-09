#!/bin/bash
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
git config core.hooksPath scripts/hooks
printf '已啟用 pre-commit hook（core.hooksPath=scripts/hooks）。\n'
