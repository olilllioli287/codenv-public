#!/bin/zsh
# 不開 App，把 Codex／Copilot／agy 的 Bridge 單獨編起來直接餵 JSON 測（替身在 stubs.swift）。用法：scripts/bridge-test/run.sh
set -e
here="$(cd -- "$(dirname -- "$0")" && pwd)"; src=$here/../../Sources/Workbench
out=$(mktemp -d); trap 'rm -rf $out' EXIT
mkdir -p "${TMPDIR}codenv-test-codex"
swiftc -o "$out/codex" "$here/stubs.swift" "$here/codex/main.swift" "$src/CodexBridge.swift" "$src/CopilotBridge.swift"
swiftc -o "$out/agy" "$here/stubs.swift" "$here/agystub.swift" "$here/agy/main.swift" "$src/AgyBridge.swift"
"$out/codex"
"$out/agy"
python3 - "$here/../exam/fake-codex-server.py" <<'PY'
import json, subprocess, sys
server = sys.argv[1]
messages = [
    {"jsonrpc":"2.0", "id":1, "method":"thread/start"},
    {"jsonrpc":"2.0", "id":2, "method":"turn/start"},
    {"jsonrpc":"2.0", "id":3, "method":"turn/interrupt", "params":{"threadId":"exam-thread", "turnId":"exam-turn"}},
]
r = subprocess.run(["python3", server], input="".join(json.dumps(m)+"\n" for m in messages), text=True, capture_output=True, check=True)
out = [json.loads(line) for line in r.stdout.splitlines()]
assert any(m.get("id") == 3 and "result" in m for m in out), "mock app-server 未確認 turn/interrupt"
assert any(m.get("method") == "turn/completed" and m["params"]["turn"]["status"] == "interrupted" for m in out), "mock app-server 未終止 turn 串流"
print("PASS fake app-server turn/interrupt fixture")
PY
defaults delete codenv-bridge-unit 2>/dev/null || true
