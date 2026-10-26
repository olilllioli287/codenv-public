#!/usr/bin/env python3
"""包 L() 有沒有改到別的東西：把每個檔案裡的 L(…)／LV(…) 包裝拆掉，跟 git HEAD 的版本比對，不一樣的地方列出來（應該只剩人工改過的少數幾處）。
用法：python3 scripts/i18n-verify.py [檔案…]（不給就檢查所有有改動的 Sources/Workbench/*.swift）"""
import difflib, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def unwrap(text):
    """拆掉程式碼裡（不在字串與註解內）的 L( … ) 與 LV( … )"""
    out, i, n = [], 0, len(text)
    stack = []          # 每個開括號：True＝這個括號是 L( 的，結尾要吃掉
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i); j = n if j < 0 else j; out.append(text[i:j]); i = j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i); j = n if j < 0 else j + 2; out.append(text[i:j]); i = j; continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3); j = n if j < 0 else j + 3; out.append(text[i:j]); i = j; continue
        if c == '"':
            j = i + 1
            depth = 0
            while j < n:
                if text[j] == "\\" and text.startswith("\\(", j): depth += 1; j += 2; continue
                if text[j] == "\\": j += 2; continue
                if depth and text[j] == "(": depth += 1
                elif depth and text[j] == ")": depth -= 1
                elif depth and text[j] == '"':      # 插值裡的字串
                    j += 1
                    while j < n and text[j] != '"': j += 2 if text[j] == "\\" else 1
                elif not depth and text[j] == '"': break
                j += 1
            out.append(text[i:j + 1]); i = j + 1; continue
        if c in "LV" and not (i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_")):
            for name in ("LV(", "L("):
                if text.startswith(name, i):
                    stack.append(True); i += len(name); break
            else:
                out.append(c); i += 1
            continue
        if c == "(": stack.append(False)
        elif c == ")":
            if stack and stack.pop(): i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def main():
    files = sys.argv[1:]
    if not files:
        st = subprocess.run(["git", "status", "--short", "Sources/Workbench"], cwd=ROOT, capture_output=True, text=True).stdout
        files = [l[3:] for l in st.splitlines() if l[3:].endswith(".swift") and not l.startswith("??")]
    bad = 0
    for f in files:
        old = subprocess.run(["git", "show", "HEAD:" + f], cwd=ROOT, capture_output=True, text=True).stdout
        new = unwrap(open(os.path.join(ROOT, f), encoding="utf-8").read())
        if unwrap(old) == new: continue
        old = unwrap(old)
        d = [l for l in difflib.unified_diff(old.split("\n"), new.split("\n"), "HEAD（也拆掉 L()）/" + f, "現在（拆掉 L()）/" + f, lineterm="", n=0) if not l.startswith("@@")]
        bad += 1
        print("\n".join(d))
    print(f"\n檢查 {len(files)} 個檔，{bad} 個拆掉 L() 後跟 HEAD 不一樣")


main()
