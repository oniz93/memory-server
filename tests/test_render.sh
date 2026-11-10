#!/usr/bin/env bash
# test_render.sh — every template renders from the example config with nothing left unrendered,
# and (where the tools exist) the results are valid systemd units and a valid compose file.
#   bash tests/test_render.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

sed -e 's#^GBRAIN_DATA_DIR=.*#GBRAIN_DATA_DIR=/mnt/bigdisk/gbrain#' -e 's#^GBRAIN_TUNNEL_PORT=.*#GBRAIN_TUNNEL_PORT=4242#' \
    "$ROOT/deploy/gbrain.conf.example" > "$T/conf"
GBRAIN_CONF="$T/conf" bash "$ROOT/deploy/install.sh" --render-only "$T/out" > "$T/log" 2>&1
check "render succeeds" '[ $? = 0 ] && [ -f "$T/out/compose.yml" ]'
check "no placeholder left" '! grep -rqE "@[A-Z_]+@" "$T/out"'
check "data dir reaches compose, units, logrotate" 'grep -q "source: /mnt/bigdisk/gbrain/pg" "$T/out/compose.yml" && grep -q "RequiresMountsFor=/mnt/bigdisk/gbrain" "$T/out/systemd/gbrain.service" && grep -q "^/mnt/bigdisk/gbrain/logs" "$T/out/logrotate-gbrain"'
check "postgres never auto-creates its data dir" 'grep -q "create_host_path: false" "$T/out/compose.yml"'
check "inbox image lives on the data disk, mount unit named after the mountpoint" 'grep -q "What=/mnt/bigdisk/gbrain/inbox.img" "$T/out/systemd/srv-gbrain-inbox.mount"'
check "tunnel port reaches the fail2ban jail" 'grep -q "port .*= http,https,4242" "$T/out/fail2ban/gbrain.local"'
check "every service waits for the data disk" '[ -z "$(grep -L "RequiresMountsFor=.*/mnt/bigdisk/gbrain" "$T/out"/systemd/*.service "$T/out"/systemd/*.mount)" ]'
check "config example is plain KEY=VALUE" '! grep -vE "^(#.*|[A-Z_]+=[A-Za-z0-9._/:@-]*)?$" "$ROOT/deploy/gbrain.conf.example" | grep -q .'
if command -v systemd-analyze >/dev/null; then
  # verify needs the referenced binaries to exist, so only syntax-level problems count here
  out="$(cd "$T/out/systemd" && systemd-analyze verify ./*.service ./*.timer ./*.mount 2>&1 | grep -vE "Command .* is not executable|No such file or directory|is not absolute|CPUAccounting|not found|Failed to prepare filename" || true)"
  check "systemd-analyze verify is clean" '[ -z "$out" ] || { echo "$out"; false; }'
fi
if docker compose version >/dev/null 2>&1; then
  check "docker compose accepts the file" 'GBRAIN_DB_PASSWORD=x docker compose -f "$T/out/compose.yml" config >/dev/null 2>"$T/compose.err" || { cat "$T/compose.err"; false; }'
fi
for f in "$ROOT"/deploy/bin/*.sh "$ROOT"/deploy/install.sh "$ROOT"/deploy/contrib/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$f" 2>/dev/null || { echo "  FAIL syntax: $f"; fail=$((fail+1)); }
done
echo "---"; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
