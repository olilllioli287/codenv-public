"""封存 README 探針的電話遮罩判斷。"""

import re


PHONE_PATTERN = re.compile(
    r"(?<!\d)(?:\+?\d{1,3}[ .()-]?)?(?:\(?\d{3}\)?[ .-]?)\d{3}[ .-]?\d{4}(?!\d)"
)
UUID_PATTERN = re.compile(
    r"(?i)(?<![0-9a-f])[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(?![0-9a-f])"
)
TIMESTAMP_PATTERNS = (
    # 常見 ISO 時間、基本 ISO 日期時間與 14 位 YYYYMMDDhhmmss。
    re.compile(
        r"(?<!\d)\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?(?!\d)"
    ),
    re.compile(r"(?<!\d)\d{8}T\d{6}(?:\.\d+)?Z?(?!\d)", re.IGNORECASE),
    re.compile(r"(?<!\d)\d{14}(?!\d)"),
    re.compile(r"(?i)(?:timestamp|unix(?:\s+time)?|時間戳)\s*[:=：]\s*\d{10,17}(?!\d)"),
)

ARCHIVE_METADATA = (
    "- 封存日期：",
    "- codenv 版本：",
    "- 聊天室 ID：",
)


def phone_scan_text(readme: str) -> str:
    """略過產生器的固定 metadata，並遮掉明確格式的 UUID／時間戳後供電話檢查。"""
    lines = readme.splitlines()
    if lines and lines[0].startswith("# "):
        cursor = 1
        while cursor < len(lines) and not lines[cursor].strip():
            cursor += 1
        metadata = lines[cursor : cursor + len(ARCHIVE_METADATA)]
        if len(metadata) == len(ARCHIVE_METADATA) and all(
            line.startswith(label) for line, label in zip(metadata, ARCHIVE_METADATA)
        ):
            del lines[cursor : cursor + len(ARCHIVE_METADATA)]

    text = "\n".join(lines)
    text = UUID_PATTERN.sub(" ", text)
    for pattern in TIMESTAMP_PATTERNS:
        text = pattern.sub(" ", text)
    return text


def phone_masked(readme: str) -> bool:
    """回傳 README 中的可掃描文字是否沒有未遮罩電話。"""
    return PHONE_PATTERN.search(phone_scan_text(readme)) is None
