#!/bin/zsh
# 不開 App，把 Codex／Copilot／agy 的 Bridge 單獨編起來直接餵 JSON 測（替身在 stubs.swift）。用法：scripts/bridge-test/run.sh
set -e
here=${0:A:h}; src=$here/../../Sources/Workbench
out=$(mktemp -d); trap 'rm -rf $out' EXIT
mkdir -p "${TMPDIR}codenv-test-codex"
swiftc -o $out/codex $here/stubs.swift $here/codex/main.swift $src/CodexBridge.swift $src/CopilotBridge.swift
swiftc -o $out/agy $here/stubs.swift $here/agystub.swift $here/agy/main.swift $src/AgyBridge.swift
$out/codex
$out/agy
defaults delete codenv-bridge-unit 2>/dev/null || true
