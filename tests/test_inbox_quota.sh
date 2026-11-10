#!/usr/bin/env bash
# test_inbox_quota.sh — the inbox is a size-capped filesystem; filling it cannot fill /.
#   sudo bash tests/test_inbox_quota.sh [/srv/gbrain/inbox]
set -uo pipefail
D="${1:-/srv/gbrain/inbox}"
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
check "inbox is its own mount" 'findmnt -n "$D" >/dev/null'
check "mounted nodev,nosuid,noexec" 'findmnt -n -o OPTIONS "$D" | grep -q nodev && findmnt -n -o OPTIONS "$D" | grep -q nosuid && findmnt -n -o OPTIONS "$D" | grep -q noexec'
size_gb=$(df -BG --output=size "$D" | tail -1 | tr -dc 0-9)
check "capped at <= 4G (got ${size_gb}G)" '[ "${size_gb:-999}" -le 4 ]'
if ! findmnt -n "$D" >/dev/null || [ "${size_gb:-999}" -gt 4 ]; then
  echo "  SKIP write probe: $D is not a capped mount (refusing to fill the root filesystem)"
  echo "---"; echo "passed $pass, failed $fail"; exit 1
fi
root_before=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
dd if=/dev/zero of="$D/.quota-probe" bs=16M count=320 status=none 2>/dev/null; rc=$?   # 5 GB attempt
root_after=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
rm -f "$D/.quota-probe"
check "oversized write fails (ENOSPC)" '[ "$rc" != 0 ]'
check "/ free space unchanged (±200M: ${root_before}M -> ${root_after}M)" '[ $(( root_before - root_after )) -lt 200 ]'
echo "---"; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
