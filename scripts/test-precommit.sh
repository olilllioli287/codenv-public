#!/bin/bash
set -eu
SOURCE_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codenv-precommit.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/empty-path"
# 用系統工具路徑跑整份測試，避免主機安裝的 gitleaks 改變測試分支。
PATH="$TMP/empty-path:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
REPO="$TMP/repo"
mkdir -p "$REPO/scripts/hooks"
cp "$SOURCE_ROOT/scripts/hooks/pre-commit" "$REPO/scripts/hooks/pre-commit"
cp "$SOURCE_ROOT/scripts/hooks/install.sh" "$REPO/scripts/hooks/install.sh"
touch "$REPO/scripts/hooks/allow-large.txt" "$REPO/scripts/hooks/allow-secrets.txt"
chmod +x "$REPO/scripts/hooks/pre-commit" "$REPO/scripts/hooks/install.sh"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "Precommit Exam"
HOOK="$REPO/scripts/hooks/pre-commit"
PASS=0
fail() { printf '失敗：%s\n' "$1" >&2; exit 1; }
clear_stage() { git -C "$REPO" reset -q; }
stage_file() { git -C "$REPO" add -- "$1"; }
expect_block() {
    label=$1; rule=$2
    if output=$(cd "$REPO" && "$HOOK" 2>&1); then fail "$label 未被攔截"; fi
    printf '%s' "$output" | grep -F "$rule" >/dev/null || fail "$label 未顯示規則"
    printf '%s' "$output" | grep -E '建議：|解除.*暫存|git rm --cached' >/dev/null || fail "$label 未提供修復建議"
    PASS=$((PASS + 1))
}
expect_quiet_pass() {
    label=$1
    output=$(cd "$REPO" && "$HOOK" 2>&1) || fail "$label 應通過"
    [ -z "$output" ] || fail "$label 通過時不安靜：$output"
    PASS=$((PASS + 1))
}

printf 'ordinary\n' > "$REPO/normal.txt"
stage_file normal.txt
expect_quiet_pass '一般檔案'
clear_stage

for path in .codex-tmp/cache.txt MyApp.app/Contents/Info.plist .build/output DerivedData/Index x.dSYM/Contents/Resources/DWARF/x .DS_Store app.log; do
    mkdir -p "$REPO/$(dirname "$path")"
    printf x > "$REPO/$path"
    stage_file "$path"
    expect_block "$path" '禁止提交暫存或建置產物路徑'
    clear_stage
done

printf 'path=/tmp/workspace\n' > "$REPO/tmp-path.txt"
stage_file tmp-path.txt
expect_block '新增 /tmp 路徑' '新增行包含 /tmp'
clear_stage
printf 'path=/private/tmp/workspace\n' > "$REPO/tmp-path.txt"
stage_file tmp-path.txt
expect_block '新增 /private/tmp 路徑' '新增行包含 /tmp'
clear_stage

dd if=/dev/zero of="$REPO/large.bin" bs=1048576 count=3 2>/dev/null
stage_file large.bin
expect_block '超過 2 MiB' '檔案大小超過 2 MiB'
printf 'large.bin\n' > "$REPO/scripts/hooks/allow-large.txt"
stage_file scripts/hooks/allow-large.txt
expect_quiet_pass '大檔白名單'
clear_stage
: > "$REPO/scripts/hooks/allow-large.txt"

printf 'credential=ghp_abcdefghijklmnopqrstuvwxyz123456\n' > "$REPO/secret.txt"
stage_file secret.txt
# 保留 git／awk 等系統工具，但排除 gitleaks，才能走內建掃描規則。
PATH="$TMP/empty-path:/usr/bin:/bin:/usr/sbin:/sbin" expect_block '內建金鑰規則' '疑似金鑰特徵'
clear_stage
printf 'credential=ghp_abcdefghijklmnopqrstuvwxyz123456 # gitleaks:allow\n' > "$REPO/secret.txt"
stage_file secret.txt
expect_quiet_pass '行內 gitleaks allow'
clear_stage
printf 'credential=ghp_abcdefghijklmnopqrstuvwxyz123456\n' > "$REPO/secret.txt"
stage_file secret.txt
printf 'secret.txt\n' > "$REPO/scripts/hooks/allow-secrets.txt"
stage_file scripts/hooks/allow-secrets.txt
expect_quiet_pass '金鑰檔名白名單'
clear_stage
: > "$REPO/scripts/hooks/allow-secrets.txt"

# A fake gitleaks executable verifies staged invocation and failure handling.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gitleaks" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$GITLEAKS_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --report-path ]; then
        shift
        printf '[{"File":"leak.txt","RuleID":"fake"}]\n' > "$1"
        break
    fi
    shift
done
exit 1
FAKE
chmod +x "$TMP/bin/gitleaks"
printf 'credential=ghp_dummy1234567890123456\n' > "$REPO/leak.txt"
stage_file leak.txt
if output=$(cd "$REPO" && PATH="$TMP/bin:$PATH" GITLEAKS_LOG="$TMP/gitleaks.log" "$HOOK" 2>&1); then fail 'gitleaks 失敗未阻擋'; fi
grep -F 'protect --staged --redact' "$TMP/gitleaks.log" >/dev/null || fail '未使用 gitleaks staged 模式'
printf '%s' "$output" | grep -F 'gitleaks 偵測到疑似金鑰' >/dev/null || fail 'gitleaks 模式未輸出規則'
PASS=$((PASS + 1))

# Verify installer config statically; do not execute it in this test.
grep -F 'git config core.hooksPath scripts/hooks' "$REPO/scripts/hooks/install.sh" >/dev/null || fail 'install.sh 未設定 core.hooksPath'
PASS=$((PASS + 1))
printf '通過：%s 項 pre-commit 考卷\n' "$PASS"
