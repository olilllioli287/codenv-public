#!/usr/bin/env python3
"""英文介面的盤點（docs/public-spec.md 第 5 節）：
  python3 scripts/i18n-report.py            各檔還沒用 L() 包的中文字串數、L() 的 key 在 en.json 裡缺幾個、en.json 多出幾個沒用到的
  python3 scripts/i18n-report.py --list     把還沒包的字串逐條列出（檔案:行號: 字串）
  python3 scripts/i18n-report.py --missing  把 L() 用到、en.json 還沒翻的 key 逐條列出
  python3 scripts/i18n-report.py --check    檢查 en.json 的翻譯：%@ 的數量要跟原文一樣（或用 %1$@ 這種編號），沒有 ⟪ ⟫
  python3 scripts/i18n-report.py --keys     把全部 L() 的 key 印成 JSON（給翻譯工具用）
字串插值 \\(x) 換成 %@，跟執行時 I18n.swift 的做法一樣。註解裡的中文不算。"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources/Workbench")
CJK = re.compile(r"[⺀-鿿＀-￯　-〿]")


def literals(text):
    """(起點, 終點, 內容（插值換成 %@）, 是否多行) 的清單；略過註解"""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i); i = n if j < 0 else j + 2; continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3); j = n if j < 0 else j
            out.append((i, j + 3, text[i + 3:j], True)); i = j + 3; continue
        if c == '"':
            j, buf = i + 1, []
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    if text.startswith("\\(", j):
                        d, k = 1, j + 2
                        while k < n and d:
                            if text[k] == "(": d += 1
                            elif text[k] == ")": d -= 1
                            elif text[k] == '"':      # 插值裡面的字串
                                k += 1
                                while k < n and text[k] != '"':
                                    k += 2 if text[k] == "\\" else 1
                            k += 1
                        buf.append("%@"); j = k; continue
                    buf.append(text[j:j + 2]); j += 2; continue
                if text[j] == "\n": break
                buf.append(text[j]); j += 1
            out.append((i, j + 1, "".join(buf), False)); i = j + 1; continue
        i += 1
    return out


def in_L_call(text, pos):
    """pos 這個字串所在的最內層括號，是不是 L( 呼叫（處理 L(cond ? "a" : "b")）"""
    depth, i = 0, pos - 1
    while i >= 0:
        c = text[i]
        if c == ")": depth += 1
        elif c == "(":
            if depth == 0:
                return bool(re.search(r"(?<![A-Za-z0-9_])L$", text[max(0, i - 2):i]))
            depth -= 1
        elif c == "\n" and i < pos - 400: return False
        i -= 1
    return False


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")


def scan():
    wrapped, bare = {}, {}
    for fn in sorted(os.listdir(SRC)):
        if not fn.endswith(".swift"): continue
        text = open(os.path.join(SRC, fn), encoding="utf-8").read()
        for a, b, s, multi in literals(text):
            if not CJK.search(s): continue
            line = text.count("\n", 0, a) + 1
            if re.search(r"\bL\(\s*$", text[max(0, a - 12):a]) or in_L_call(text, a):
                wrapped.setdefault(fn, []).append((line, unescape(s)))
            else:
                bare.setdefault(fn, []).append((line, unescape(s), multi))
    return wrapped, bare


def js_keys():
    """Resources/chat/chat.js 裡的 L('…')、L("…")、L`…${x}…` 的 key（插值換成 %@，跟執行時一樣）"""
    text = open(os.path.join(ROOT, "Resources/chat/chat.js"), encoding="utf-8").read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)                  # 註解裡的 L('…') 不算
    text = re.sub(r"(?m)(^|[\s;{}(),])//.*$", r"\1", text)
    keys = set()
    for m in re.finditer(r"(?<![A-Za-z0-9_$.])L\(\s*('((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\")\s*\)", text):
        k = m.group(2) if m.group(2) is not None else m.group(3)
        if CJK.search(k): keys.add(re.sub(r"\\(.)", lambda x: {"n": "\n", "t": "\t"}.get(x.group(1), x.group(1)), k))
    for m in re.finditer(r"(?<![A-Za-z0-9_$.])L`((?:[^`\\]|\\.)*)`", text):
        k = re.sub(r"\$\{(?:[^{}]|\{[^{}]*\})*\}", "%@", m.group(1))
        if CJK.search(k): keys.add(re.sub(r"\\(.)", lambda x: {"n": "\n", "t": "\t"}.get(x.group(1), x.group(1)), k))
    return keys


def main():
    args = sys.argv[1:]
    wrapped, bare = scan()
    table = json.load(open(os.path.join(ROOT, "Resources/i18n/en.json"), encoding="utf-8"))
    swift_keys = {s for v in wrapped.values() for _, s in v}
    jsk = js_keys()
    keys = sorted(swift_keys | jsk)
    if "--keys" in args:
        print(json.dumps(keys, ensure_ascii=False, indent=1)); return
    if "--missing" in args:
        for k in keys:
            if not table.get(k): print(k)
        return
    if "--check" in args:
        bad = 0
        for k, v in table.items():
            if not v: continue
            n = k.count("%@")
            nums = sorted(re.findall(r"%(\d+)\$@", v))
            ok = (v.count("%@") == n and not nums) or (not v.count("%@") and nums == [str(i + 1) for i in range(n)])
            if not ok or "⟪" in v:
                bad += 1; print(f"佔位符對不上：{k!r} → {v!r}")
        print(f"檢查 {sum(1 for v in table.values() if v)} 條翻譯，{bad} 條有問題")
        return
    if "--list" in args:
        for fn, v in bare.items():
            for line, s, multi in v: print(f"{fn}:{line}: {s!r}{' (多行)' if multi else ''}")
        return
    nb = sum(len(v) for v in bare.values())
    print(f"還沒用 L() 包的中文字串：{nb} 個，分布在 {len(bare)} 個檔案")
    for fn, v in sorted(bare.items(), key=lambda x: -len(x[1])): print(f"  {len(v):4d}  {fn}")
    miss = [k for k in keys if not table.get(k)]
    unused = [k for k in table if k not in keys]
    print(f"L() 的 key：{len(keys)} 個（Swift {len(swift_keys)}、chat.js {len(jsk)}，重複的算一個）；en.json 還沒翻：{len(miss)} 個；en.json 多出沒用到的：{len(unused)} 個")


main()
