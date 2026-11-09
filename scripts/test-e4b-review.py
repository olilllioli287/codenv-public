#!/usr/bin/env python3
"""靜態驗收輔助：不啟動 App、模型、測試視窗，也不碰使用者資料。"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
review = (ROOT / "Sources/Workbench/E4BReview.swift").read_text()
prefs = (ROOT / "Sources/Workbench/Prefs.swift").read_text()
settings = (ROOT / "Sources/Workbench/SettingsPages.swift").read_text()
memory = (ROOT / "Sources/Workbench/MemoryAdvice.swift").read_text()

assert "minimumAvailableRAM: UInt64 = 9 * 1024 * 1024 * 1024" in review
assert "127.0.0.1:8794/v1/chat/completions" in review
assert "AppDefaults.e4bDailyReviewEnabled" in prefs
assert "E4B 每日檢討（建議記憶與技能）" in settings
assert "addMemoryProposal" in memory
assert "write(to:" not in review and "MEMORY.md" in review
assert "e4bDailyReviewEnabled" in review
print("E4B review static checks passed")
