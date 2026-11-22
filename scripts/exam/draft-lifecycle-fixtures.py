#!/usr/bin/env python3
"""Create disposable e74b99b draft/handoff fixtures; generated keys are never printed."""
import hashlib
import json
import os
import secrets
import string
import sys
from pathlib import Path

MIB = 1024 * 1024
ALNUM = string.ascii_letters + string.digits
PNG_1X1 = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"
)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def write_padded(path, size, prefix, pad):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.write(prefix)
        remaining = size - len(prefix)
        if remaining < 0:
            raise ValueError(f"fixture prefix exceeds target: {path.name}")
        while remaining:
            block = pad[:remaining]
            stream.write(block)
            remaining -= len(block)


def main():
    if len(sys.argv) != 2:
        print("用法：draft-lifecycle-fixtures.py </tmp 下的新暫存目錄>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    resolved = root.resolve()
    tmp_root = Path("/tmp").resolve()
    if os.path.commonpath([str(tmp_root), str(resolved)]) != str(tmp_root):
        print("拒絕：fixture 目錄必須位於 /tmp 暫存樹下", file=sys.stderr)
        return 2
    try:
        root.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        print("拒絕：fixture 目錄已存在，請使用新的暫存目錄", file=sys.stderr)
        return 2

    small = root / "draft-under-1m.txt"
    write_padded(small, 900 * 1024, "synthetic small draft\n".encode(), b"small synthetic draft padding\n")

    large = root / "draft-over-1m.txt"
    fake = ("sk-" + "".join(secrets.choice(ALNUM) for _ in range(40))).encode("ascii")
    large_prefix = b"synthetic large draft; exam-only fake credential=" + fake + b"\n"
    write_padded(large, 1280 * 1024, large_prefix, b"large synthetic draft padding\n")

    image = root / "handoff-image.png"
    image.write_bytes(PNG_1X1)
    file_card = root / "handoff-file-card.txt"
    file_card.write_text("synthetic file card content\n", encoding="utf-8")

    manifest = {
        "schemaVersion": 1,
        "syntheticOnly": True,
        "smallDraft": {"path": str(small), "bytes": small.stat().st_size, "sha256": digest(small)},
        "largeDraft": {
            "path": str(large), "bytes": large.stat().st_size, "sha256": digest(large),
            "fakeCredentialSha256": hashlib.sha256(fake).hexdigest(),
            "fakeCredentialTextIncluded": False,
        },
        "handoffImage": {"path": str(image), "bytes": image.stat().st_size},
        "handoffFileCard": {"path": str(file_card), "bytes": file_card.stat().st_size, "sha256": digest(file_card)},
    }
    manifest_path = root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(manifest_path), "fakeCredentialLogged": False}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
