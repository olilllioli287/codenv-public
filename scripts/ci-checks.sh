#!/bin/bash
# Run exam cases that do not launch the app, a browser, or public export.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

run_exam() {
    local runner="$1" id="$2"
    echo "==> $id ($runner)"
    case "$runner" in
        *.py) python3 "scripts/exam/$runner" "$id" "$ROOT" ;;
        *.mjs) node "scripts/exam/$runner" "$id" "$ROOT" ;;
        keyvault.sh) bash "scripts/exam/$runner" "$id" "$ROOT" ;;
        ../bridge-test/run.sh) bash scripts/bridge-test/run.sh ;;
        *) echo "Unsupported CI runner: $runner" >&2; exit 2 ;;
    esac
}

# Keep this list to deterministic, headless runners. Native and browser runners
# need a GUI; export-guard performs an export. K01 uses only test-prefixed
# keychain entries and cleans them up when it exits.
for id in A06 A03 A05 A01 A02 C65 A07 A08 A13 A14 A15 A16 A17 A20 C80 A18 A21 A22 A11 A12 C50 C51 K01; do
    case "$id" in
        A06|A03|A05|A01|A02|C80) runner=logic.mjs ;;
        C65) runner=../bridge-test/run.sh ;;
        A07|A08|A13|A14|A15|A16|A17|A20|A18|A21|A22) runner=todo.py ;;
        A11|A12|C50|C51) runner=holdout/todo.py ;;
        K01) runner=keyvault.sh ;;
    esac
    run_exam "$runner" "$id"
done
