#!/usr/bin/env bash
# test_unit_sandbox.sh — run a probe inside the exact [Service] sandbox of a unit file and check
# that escalation / destructive paths are closed while the paths the service needs stay writable.
#   sudo bash tests/test_unit_sandbox.sh <unit-file> <must-be-writable-dir>...
set -uo pipefail
UNIT="$1"; shift
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1 (got $2, want $3)"; fail=$((fail+1)); fi; }

# Carry over every sandbox-relevant [Service] property of the unit.
props=()
while IFS= read -r line; do
  case "$line" in
    ''|'#'*|'['*) continue ;;
    ExecStart*|ExecStartPre*|Type=*|Restart*|Standard*|TimeoutStartSec=*|WorkingDirectory=*|Nice=*|IOScheduling*|EnvironmentFile=*) continue ;;
  esac
  props+=(-p "$line")
done < <(sed -n '/^\[Service\]/,/^\[/p' "$UNIT" | grep -v '^\[' | sed -e ':a;/\\$/N;s/\\\n//;ta')

# Home directory of the unit's User= (the sandbox must leave it readable but not writable).
unit_user="$(sed -n 's/^User=//p' "$UNIT" | head -1)"
uhome="$(getent passwd "${unit_user:-root}" | cut -d: -f6)"
bun_bin="$(sed -n 's/^Environment=PATH=\([^:]*\):.*/\1/p' "$UNIT" | head -1)"

probe='
r() { if eval "$1" >/dev/null 2>&1; then echo "$2=yes"; else echo "$2=no"; fi; }
r "sudo -n true" sudo
r "curl -s -m3 --unix-socket /run/docker.sock http://x/_ping" docker
r "touch '"$uhome"'/.gbrain-sandbox-probe && rm -f '"$uhome"'/.gbrain-sandbox-probe" home_write
r "test -r '"$bun_bin"'/bun" bun_read
r "touch /etc/gbrain-sandbox-probe && rm -f /etc/gbrain-sandbox-probe" etc_write
for d in '"$*"'; do r "touch $d/.sandbox-probe && rm -f $d/.sandbox-probe" "rw:$d"; done
'
out="$(systemd-run --quiet --wait --pipe --collect "${props[@]}" /bin/bash -c "$probe" 2>&1)"
echo "$out" | sed 's/^/    /'
get() { echo "$out" | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }'; }
check "sudo blocked"            "$(get sudo)"       no
check "docker socket blocked"   "$(get docker)"     no
check "home not writable"       "$(get home_write)" no
check "bun still readable"      "$(get bun_read)"   yes
check "/etc not writable"       "$(get etc_write)"  no
for d in "$@"; do check "writable: $d" "$(get "rw:$d")" yes; done
echo "---"; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
