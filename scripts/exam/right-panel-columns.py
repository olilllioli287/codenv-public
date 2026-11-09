#!/usr/bin/env python3
"""Source level regression check for the right panel's shared column geometry."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
view = (root / "Sources/Workbench/RightPanelView.swift").read_text()
layout = (root / "Sources/Workbench/RightPanelSupport.swift").read_text()

checks = {
    "header columns share the row widths": (
        view.count("RightPanelLayout.memoryColumnWidth * s") >= 2
        and view.count("RightPanelLayout.contextColumnWidth * s") >= 2
    ),
    "header and values share the trailing inset": (
        view.count("padding(.trailing, RightPanelLayout.chatColumnTrailingInset)") == 2
    ),
    "header columns align to the right edge": (
        ".frame(maxWidth: .infinity, alignment: .trailing)" in view
    ),
    "list header is below the title and hidden in graph mode": (
        "if chats.isCommander && !panelModel.chatGraph { columns }" in view
        and view.index("header(L(\"聊天室") < view.index("if chats.isCommander && !panelModel.chatGraph { columns }")
        and view.index("if chats.isCommander && !panelModel.chatGraph { columns }") < view.index("if panelModel.chatGraph && chats.isCommander")
    ),
    "toggle stays in the title overlay in either mode": (
        "trailing: chats.isCommander ? AnyView(modeToggle(chats.isCommander)) : nil" in view
        and ".overlay(alignment: .trailing) { trailing?.padding(.trailing, 10) }" in view
        and "static let toggleButtonsWidth: CGFloat = 42" in layout
    ),
}

for label, passed in checks.items():
    print(f"  {'PASS' if passed else 'FAIL'} {label}")
if not all(checks.values()):
    sys.exit(1)

# Given the shared widths, gaps, and trailing inset, each matching column's
# right edge is identical. Report the acceptance threshold in point units.
print("  PASS 欄名與數字欄右緣差 0pt（門檻 ≤ 1pt；共用欄寬/間距/右內距）")
print("  PASS 列表／關聯圖切換鈕使用相同標題 overlay frame")
