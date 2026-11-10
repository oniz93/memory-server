#!/usr/bin/env bash
# test_inbox_key.sh — tests for deploy/bin/inbox-key.sh against a temp authorized_keys.
#   bash tests/test_inbox_key.sh [path/to/inbox-key.sh]
set -uo pipefail
SCRIPT="$(realpath "${1:-$(dirname "$0")/../deploy/bin/inbox-key.sh}")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

mkdir -p "$T/inbox" "$T/bin"
printf 'alice: research-alpha\nbob: research-alpha\n' > "$T/policy"
ssh-keygen -q -t ed25519 -N '' -C owner -f "$T/owner"; ssh-keygen -q -t ed25519 -N '' -f "$T/k1"; ssh-keygen -q -t ed25519 -N '' -f "$T/k2"
reset_ak() { cp "$T/owner.pub" "$T/ak"; chmod 600 "$T/ak"; }
ik() { env AUTHORIZED_KEYS="$T/ak" GBRAIN_INBOX="$T/inbox" GBRAIN_INBOX_POLICY="$T/policy" \
          GBRAIN_CONF="$T/none.conf" GBRAIN_CONF_OPTIONAL=1 GBRAIN_ROOT="$T/root" "$@"; }

echo "K1 forced command munges symlinks and forbids deletes"
reset_ak; ik bash "$SCRIPT" add alice "$T/k1.pub" >/dev/null 2>&1
check "rrsync runs with -munge -no-del -wo" 'grep -q "command=\"/usr/bin/rrsync -munge -no-del -wo $T/inbox/alice\"" "$T/ak"'
check "restrict option present" 'grep -q "^restrict,command=" "$T/ak"'
check "owner key kept" 'grep -qF "$(cut -d" " -f2 "$T/owner.pub")" "$T/ak"'

echo "K2 remove refuses a non-literal / invalid name"
reset_ak; ik bash "$SCRIPT" add alice "$T/k1.pub" >/dev/null 2>&1; ik bash "$SCRIPT" add bob "$T/k2.pub" >/dev/null 2>&1
ik bash "$SCRIPT" remove 'collab.' >/dev/null 2>&1; rc=$?
check "exit non-zero" '[ "$rc" != 0 ]'
check "both collaborator keys still there" '[ "$(grep -c " gbrain-inbox:" "$T/ak")" = 2 ]'

echo "K3 a failing filter (grep/awk) never truncates authorized_keys"
reset_ak; ik bash "$SCRIPT" add alice "$T/k1.pub" >/dev/null 2>&1
before="$(sha256sum < "$T/ak")"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = -v ] && exit 2; done\nexec /usr/bin/grep "$@"\n' > "$T/bin/grep"
printf '#!/usr/bin/env bash\nexit 2\n' > "$T/bin/awk"; chmod +x "$T/bin/grep" "$T/bin/awk"
PATH="$T/bin:$PATH" ik bash "$SCRIPT" remove alice >/dev/null 2>&1; rc=$?
check "exit non-zero" '[ "$rc" != 0 ]'
check "file unchanged" '[ "$(sha256sum < "$T/ak")" = "$before" ]'
rm -f "$T/bin/grep" "$T/bin/awk"

echo "K4 remove works and keeps everything else"
reset_ak; ik bash "$SCRIPT" add alice "$T/k1.pub" >/dev/null 2>&1; ik bash "$SCRIPT" add bob "$T/k2.pub" >/dev/null 2>&1
ik bash "$SCRIPT" remove alice >/dev/null 2>&1
check "alice gone, bob + owner kept" '! grep -q "gbrain-inbox:alice$" "$T/ak" && grep -q "gbrain-inbox:bob$" "$T/ak" && grep -qF "$(cut -d" " -f2 "$T/owner.pub")" "$T/ak"'

echo "---"; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
