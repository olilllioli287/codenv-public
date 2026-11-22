#!/usr/bin/env python3
"""Runtime-only, synthetic fixtures for e74b99. Never prints generated key text."""
import hashlib
import json
import os
import secrets
import string
import sys
from pathlib import Path

MIB = 1024 * 1024
ALNUM = string.ascii_letters + string.digits


def fake_key():
    # EXAM-ONLY fake credential; fresh random payload on every invocation.
    return "sk-" + "".join(secrets.choice(ALNUM) for _ in range(40))


def random_hex(length=64):
    return secrets.token_hex((length + 1) // 2)[:length]


def write_filled(path, target_size, prefix, fill):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        output.write(prefix)
        remaining = target_size - len(prefix)
        if remaining < 0:
            raise ValueError(f"fixture prefix exceeds target size: {path.name}")
        while remaining:
            chunk = fill[:remaining]
            output.write(chunk)
            remaining -= len(chunk)


def write_large_html(path, target_size, include_fake_findings=False):
    tags = b"".join(
        f"<meta name='exam-{i}' content='{random_hex(64)}'>".encode("ascii")
        for i in range(48)
    )
    prefix = "<!doctype html><html><body>合成測試資料".encode("utf-8") + tags + b"\xff"
    fake_offsets = {}
    if include_fake_findings:
        strong = fake_key().encode("ascii")
        weak = ("key=" + random_hex(64)).encode("ascii")
        high_entropy = secrets.token_urlsafe(72).encode("ascii")
        prefix += b"<div>synthetic=" + strong + b"</div><div>" + weak + b"</div><div>" + high_entropy + b"</div>"
        fake_offsets = {
            "strongPrefixOffset": prefix.find(strong),
            "weakCandidateOffset": prefix.find(weak),
            "highEntropyCandidateOffset": prefix.find(high_entropy),
        }
    filler = b"<p data-exam='" + random_hex(128).encode("ascii") + b"'>synthetic padding</p>"
    filler += b"x" * (4096 - len(filler))
    write_filled(path, target_size, prefix, filler)
    return fake_offsets


def write_after_limit_case(path, include_early_hit):
    first = "前段合成文字".encode("utf-8")
    if include_early_hit:
        first += fake_key().encode("ascii")
    tail = b"<meta name='exam-tail' content='" + fake_key().encode("ascii") + b"'>"
    offset = 8 * MIB + 1024
    filler = b"<meta name='exam-padding' content='" + random_hex(128).encode("ascii") + b"'>"
    filler += b"x" * (4096 - len(filler))
    target_size = 20 * MIB
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        output.write(first)
        remaining = offset - len(first)
        block = filler * 8192
        while remaining:
            chunk = block[:remaining]
            output.write(chunk)
            remaining -= len(chunk)
        tail_offset = output.tell()
        output.write(tail)
        remaining = target_size - output.tell()
        while remaining:
            chunk = block[:remaining]
            output.write(chunk)
            remaining -= len(chunk)
    return {
        "firstHitOffset": len("前段合成文字".encode("utf-8")) if include_early_hit else None,
        "afterLimitHitOffset": tail_offset,
        "targetBytes": target_size,
    }


def make_fixtures(root):
    root.mkdir(parents=True, exist_ok=False)
    manifest = {"schemaVersion": 1, "syntheticOnly": True, "cases": {}}

    g1 = root / "G1-large"
    html = g1 / "large-one-line.html"
    pdf = g1 / "fake.pdf"
    write_large_html(html, 20 * MIB, include_fake_findings=False)
    pdf_prefix = b"%PDF-1.7\n% synthetic exam bytes only\n"
    write_filled(pdf, 5 * MIB, pdf_prefix, secrets.token_bytes(64 * 1024))
    manifest["cases"]["G1"] = {
        "html": {"path": str(html), "bytes": html.stat().st_size, "lines": 1},
        "pdf": {"path": str(pdf), "bytes": pdf.stat().st_size, "synthetic": True},
    }

    g2 = root / "G2-findings"
    html = g2 / "large-one-line-with-synthetic-findings.html"
    offsets = write_large_html(html, 20 * MIB, include_fake_findings=True)
    manifest["cases"]["G2"] = {
        "html": {"path": str(html), "bytes": html.stat().st_size, "lines": 1},
        "generatedFindingOffsets": offsets,
        "fakeCredentialValuesIncludedInManifest": False,
    }

    g3 = root / "G3-scan-limit"
    html_tail_only = g3 / "hit-only-after-8mib.html"
    tail_only_offsets = write_after_limit_case(html_tail_only, include_early_hit=False)
    html_both = g3 / "hits-before-and-after-8mib.html"
    both_offsets = write_after_limit_case(html_both, include_early_hit=True)
    manifest["cases"]["G3"] = {
        "tailOnly": {"path": str(html_tail_only), "bytes": html_tail_only.stat().st_size, "offsets": tail_only_offsets},
        "earlyAndTail": {"path": str(html_both), "bytes": html_both.stat().st_size, "offsets": both_offsets},
        "fakeCredentialValuesIncludedInManifest": False,
    }

    g4 = root / "G4-differential"
    corpus = g4 / "synthetic-differential-corpus.bin"
    values = [
        "non-ascii 前文 sk-" + "".join(secrets.choice(ALNUM) for _ in range(40)),
        "key=" + random_hex(64),
        "long-line=" + " ".join(random_hex(64) for _ in range(128)),
        "<meta name='ﬁ-key' content='" + random_hex(48) + "'>",
        "＜meta name='exam-zero-width' content='" + random_hex(48) + "'＞",
        "\u200b<meta name='exam-zero-width-inner' content='" + random_hex(48) + "'>\u200b",
        "overlap key=" + random_hex(48) + " token=" + random_hex(48),
    ]
    corpus.parent.mkdir(parents=True, exist_ok=True)
    corpus.write_bytes(("\r\n".join(values) + "\r\u0085\u2028\u2029").encode("utf-8") + b"\xff")
    allow_seed = "e74b99 synthetic allow seed " + secrets.token_hex(8)
    learning_seed = "e74b99 synthetic learned feature " + secrets.token_hex(8)
    settings = g4 / "synthetic-state.json"
    settings.write_text(json.dumps({
        "allowHashes": [hashlib.sha256(allow_seed.encode("utf-8")).hexdigest()],
        "learnedFeatureCounts": {learning_seed: 2},
    }, ensure_ascii=False))
    manifest["cases"]["G4"] = {
        "corpus": {"path": str(corpus), "bytes": corpus.stat().st_size},
        "stateSeed": {"path": str(settings), "nonEmptyAllowHashes": True, "nonEmptyLearnedFeatureCounts": True},
        "note": "須與未修改 07.11 對同一語料的完整 findings／redact golden 對拍；實際掛鉤仍待 TODO 對齊。",
    }

    g7 = root / "G7-unscanned"
    g7.mkdir(parents=True, exist_ok=True)
    unreadable = g7 / "permission-denied.txt"
    unreadable.write_text("synthetic unreadable attachment")
    unreadable.chmod(0)
    directory = g7 / "directory-attachment"
    directory.mkdir()
    (directory / "inside.txt").write_text("synthetic directory content")
    app_package = g7 / "synthetic.app"
    (app_package / "Contents").mkdir(parents=True)
    (app_package / "Contents" / "Info.plist").write_text("synthetic package marker")
    rtfd = g7 / "synthetic.rtfd"
    rtfd.mkdir()
    (rtfd / "TXT.rtf").write_text("synthetic RTFD content")
    target = g7 / "symlink-target.txt"
    target.write_text("synthetic symlink target")
    symlink = g7 / "symlink-attachment"
    symlink.symlink_to(target.name)
    fifo = g7 / "synthetic.fifo"
    os.mkfifo(fifo)
    manifest["cases"]["G7"] = {
        "unreadable": str(unreadable), "directory": str(directory), "appPackage": str(app_package),
        "rtfdPackage": str(rtfd), "symlink": str(symlink), "fifo": str(fifo),
        "note": "FIFO 僅建立、不在產生器中開啟；測試需證明 fail-closed 且不阻塞。",
    }

    g8 = root / "G8-large-paste"
    text = g8 / "large-text-with-synthetic-key.txt"
    text_prefix = ("synthetic text 前文 " + fake_key() + " ").encode("utf-8")
    write_filled(text, 20 * MIB, text_prefix, b"synthetic paste text without newlines ")
    manifest["cases"]["G8"] = {"text": {"path": str(text), "bytes": text.stat().st_size}}

    # G9/G10 reuse the generated large attachments as isolated callback fixtures.
    manifest["cases"]["G9"] = {"scanAttachment": manifest["cases"]["G1"]["html"]["path"]}
    manifest["cases"]["G10"] = {"scanAttachment": manifest["cases"]["G2"]["html"]["path"]}
    manifest["cases"]["G11"] = {
        "unreadable": str(unreadable), "symlink": str(symlink), "fifo": str(fifo),
        "note": "與 G7 不同，須明驗背景核心結果為 unscanned 而非 clean。",
    }

    g12 = root / "G12-thread-safety"
    redact_input = g12 / "synthetic-redact-input.txt"
    redact_input.parent.mkdir(parents=True, exist_ok=True)
    redact_input.write_text(
        "synthetic concurrency fixture " + fake_key() + " key=" + random_hex(64)
        + " feature=" + secrets.token_hex(12),
        encoding="utf-8",
    )
    manifest["cases"]["G12"] = {
        "redactInput": {"path": str(redact_input), "bytes": redact_input.stat().st_size},
        "mainThreadMutationRounds": 1000,
        "note": "假憑證只在執行時生成；manifest 不含明文。",
    }

    manifest_path = root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"manifest": str(manifest_path), "caseIDs": list(manifest["cases"]), "fakeCredentialsLogged": False}, ensure_ascii=False))


def main():
    if len(sys.argv) != 2:
        print("用法：keyguard-async-fixtures.py <新建的 /tmp 暫存目錄>", file=sys.stderr)
        return 2
    output_root = Path(sys.argv[1])
    canonical_root = output_root.resolve()
    temp_root = Path("/tmp").resolve()
    if os.path.commonpath([str(temp_root), str(canonical_root)]) != str(temp_root):
        print("拒絕：fixture 目錄必須位於 /tmp 暫存樹下", file=sys.stderr)
        return 2
    try:
        make_fixtures(output_root)
    except FileExistsError:
        print("拒絕：fixture 目錄已存在，請使用新的暫存目錄", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
