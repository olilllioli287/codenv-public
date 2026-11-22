#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/release.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codenv-gate-selftest.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/fake-zero.sh" <<'SH'
#!/bin/sh
printf '%s\n' '總結：通過 0、失敗 0、略過 0（dev）'
exit 0
SH
cat > "$TEST_DIR/fake-no-summary.sh" <<'SH'
#!/bin/sh
printf '%s\n' '假考卷輸出，但沒有總結'
exit 0
SH
chmod +x "$TEST_DIR/fake-zero.sh" "$TEST_DIR/fake-no-summary.sh"
"$TEST_DIR/fake-zero.sh" > "$TEST_DIR/zero.log"
"$TEST_DIR/fake-no-summary.sh" > "$TEST_DIR/missing.log"
printf '%s\n' '總結：通過 5、失敗 0' > "$TEST_DIR/pass.log"
printf '%s\n' '總結：通過 3、失敗 1、略過 0（dev）' > "$TEST_DIR/fail.log"
printf '%s\n' '總結：通過 0、失敗 0、略過 0（前一輪）' '總結：通過 7、失敗 0、略過 0（最後一輪）' > "$TEST_DIR/multi-summary.log"
printf '%s\n' '總結：通過 5、失敗 0、略過 2' > "$TEST_DIR/skip-no-suffix.log"
printf '%s\n' '總結：通過 5、失敗 0、略過 2（全套）' > "$TEST_DIR/skip-with-suffix.log"

check_case() {
    local name="$1" expected="$2" file="$3" actual
    if release_exam_verdict "$file"; then actual=0; else actual=$?; fi
    printf 'CASE %s actual=%s kind=%s expected=%s\n' "$name" "$actual" "$RELEASE_EXAM_VERDICT_KIND" "$expected"
    [[ "$actual" -eq "$expected" ]]
}

check_case pass5_fail0 0 "$TEST_DIR/pass.log"
check_case zero_tests 1 "$TEST_DIR/zero.log"
check_case missing_summary 1 "$TEST_DIR/missing.log"
check_case pass3_fail1 1 "$TEST_DIR/fail.log"
check_case multi_summary_last_pass 0 "$TEST_DIR/multi-summary.log"
check_case skip_no_suffix 0 "$TEST_DIR/skip-no-suffix.log"
check_case skip_with_suffix 0 "$TEST_DIR/skip-with-suffix.log"
