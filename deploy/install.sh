#!/usr/bin/env bash
# install.sh — install or update the GBrain server from this checkout. Safe to re-run.
#
#   sudo deploy/install.sh                     install / update using /etc/gbrain/gbrain.conf
#   sudo deploy/install.sh --with-fail2ban     also apt-install fail2ban (the gbrain jail only)
#   sudo deploy/install.sh --no-start          install files and units, start nothing
#   deploy/install.sh --render-only DIR        render every template into DIR and exit (no root,
#                                              changes nothing; GBRAIN_CONF=<file> picks the config)
#
# First run: creates /etc/gbrain/gbrain.conf from the example and stops so you can edit it
# (at least GBRAIN_USER, GBRAIN_DATA_DIR, GBRAIN_BUN_BIN). To move data later use
# bin/move-data.sh; never just edit GBRAIN_DATA_DIR.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
export GBRAIN_CONF="${GBRAIN_CONF:-/etc/gbrain/gbrain.conf}"
RENDER_ONLY=""; START=1; WITH_F2B=0
while [ $# -gt 0 ]; do
  case "$1" in
    --render-only) RENDER_ONLY="${2:?--render-only needs a directory}"; shift 2 ;;
    --no-start) START=0; shift ;;
    --with-fail2ban) WITH_F2B=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
say() { printf '==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

if [ ! -r "$GBRAIN_CONF" ]; then
  [ -z "$RENDER_ONLY" ] || die "config not found: $GBRAIN_CONF"
  [ "$(id -u)" = 0 ] || die "run with sudo"
  install -D -m0644 "$HERE/gbrain.conf.example" "$GBRAIN_CONF"
  say "created $GBRAIN_CONF from the example."
  say "edit it (GBRAIN_USER, GBRAIN_DATA_DIR, GBRAIN_BUN_BIN at least), then run this again."
  exit 0
fi
. "$HERE/bin/gbrain-env.sh"

# ---------------------------------------------------------------- validation + derived values
for v in GBRAIN_HTTP_PORT GBRAIN_PG_PORT GBRAIN_SHIM_PORT GBRAIN_TUNNEL_PORT GBRAIN_PG_MEM_MB GBRAIN_SERVE_MEM_MB; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a number (got '${!v}')"
done
for v in GBRAIN_ROOT GBRAIN_DATA_DIR GBRAIN_BUN_BIN; do
  [[ "${!v}" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "$v must be an absolute path without spaces (got '${!v}')"
done
[[ "$GBRAIN_INBOX_SIZE" =~ ^[0-9]+[MG]$ ]] || die "GBRAIN_INBOX_SIZE must look like 2G or 500M"
if [ -z "$RENDER_ONLY" ]; then
  [ "$(id -u)" = 0 ] || die "run with sudo"
  id "$GBRAIN_USER" >/dev/null 2>&1 || die "user '$GBRAIN_USER' does not exist (GBRAIN_USER in $GBRAIN_CONF)"
  command -v docker >/dev/null || die "docker is required"
  docker compose version >/dev/null 2>&1 || die "the docker compose plugin is required"
  for c in pg_isready rsync python3 openssl; do command -v "$c" >/dev/null || die "missing command: $c"; done
  USER_HOME="$(getent passwd "$GBRAIN_USER" | cut -d: -f6)"
  GROUP="$(id -gn "$GBRAIN_USER")"
  INBOX_UNIT="$(systemd-escape -p --suffix=mount "$GBRAIN_INBOX")"
else
  USER_HOME="/home/$GBRAIN_USER"; GROUP="$GBRAIN_USER"
  INBOX_UNIT="$(systemd-escape -p --suffix=mount "$GBRAIN_INBOX" 2>/dev/null || echo "$(echo "${GBRAIN_INBOX#/}" | tr / -).mount")"
fi

render() { # <template> -> stdout
  sed -e "s#@ROOT@#$GBRAIN_ROOT#g" -e "s#@DATA@#$GBRAIN_DATA_DIR#g" \
      -e "s#@USER@#$GBRAIN_USER#g" -e "s#@GROUP@#$GROUP#g" -e "s#@USER_HOME@#$USER_HOME#g" \
      -e "s#@BUN_BIN@#$GBRAIN_BUN_BIN#g" \
      -e "s#@HTTP_PORT@#$GBRAIN_HTTP_PORT#g" -e "s#@PG_PORT@#$GBRAIN_PG_PORT#g" \
      -e "s#@SHIM_PORT@#$GBRAIN_SHIM_PORT#g" -e "s#@TUNNEL_PORT@#$GBRAIN_TUNNEL_PORT#g" \
      -e "s#@PG_MEM_MB@#$GBRAIN_PG_MEM_MB#g" -e "s#@PG_MEMSWAP_MB@#$(( GBRAIN_PG_MEM_MB + 256 ))#g" \
      -e "s#@SERVE_MEM_MB@#$GBRAIN_SERVE_MEM_MB#g" -e "s#@SERVE_MEM_HIGH_MB@#$(( GBRAIN_SERVE_MEM_MB * 5 / 6 ))#g" \
      -e "s#@INBOX_UNIT@#$INBOX_UNIT#g" -e "s#@INBOX_SIZE@#$GBRAIN_INBOX_SIZE#g" "$1"
}

render_all() { # <dir>: every rendered file, laid out by destination
  local d="$1" t
  mkdir -p "$d/systemd" "$d/fail2ban"
  render "$HERE/compose.yml.in" > "$d/compose.yml"
  for t in "$HERE"/systemd/*.in; do
    case "$(basename "$t")" in
      inbox.mount.in) render "$t" > "$d/systemd/$INBOX_UNIT" ;;
      *) render "$t" > "$d/systemd/$(basename "$t" .in)" ;;
    esac
  done
  render "$HERE/logrotate.in" > "$d/logrotate-gbrain"
  render "$HERE/fail2ban/gbrain.jail.local.in" > "$d/fail2ban/gbrain.local"
  if grep -rn '@[A-Z_]*@' "$d" | grep -v 'HTTP_PORT@' ; then die "unrendered placeholder(s) above"; fi
}

if [ -n "$RENDER_ONLY" ]; then
  render_all "$RENDER_ONLY"
  say "rendered into $RENDER_ONLY (nothing installed)"
  exit 0
fi

# install_if_changed <src> <dst> <mode> [owner:group] ; returns 0 when dst was created/changed
install_if_changed() {
  local src="$1" dst="$2" mode="$3" own="${4:-root:root}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst"; chown "$own" "$dst"; return 1
  fi
  install -D -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$src" "$dst"
}

MARK="$GBRAIN_ETC/.installed"
OWN="$GBRAIN_USER:$GROUP"

# ---------------------------------------------------------------- directories
say "directories (root $GBRAIN_ROOT, data $GBRAIN_DATA_DIR)"
data_parent="$(dirname "$GBRAIN_DATA_DIR")"
[ -d "$data_parent" ] || die "$data_parent does not exist: is the data disk mounted?"
if [ -f "$MARK" ] && [ ! -d "$GBRAIN_PG_DIR" ]; then
  die "$GBRAIN_PG_DIR is missing on an existing install. Data disk not mounted? To relocate data use bin/move-data.sh. Refusing to create an empty database."
fi
install -d -m0750 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_ROOT"
for d in bin etc nginx home repos sources; do install -d -m0750 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_ROOT/$d"; done
install -d -m0700 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_SECRETS" "$GBRAIN_SECRETS/tokens"
install -d -m0750 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_DATA_DIR" "$GBRAIN_LOG_DIR"
install -d -m0700 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_BACKUP_DIR"
[ -d "$GBRAIN_PG_DIR" ] || install -d -m0700 "$GBRAIN_PG_DIR"     # the postgres image chowns it on first start

# ---------------------------------------------------------------- secrets (generated once, never printed)
umask 077
[ -s "$GBRAIN_SECRETS/db.env" ] || { printf 'GBRAIN_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$GBRAIN_SECRETS/db.env"; say "generated the database password"; }
[ -s "$GBRAIN_SECRETS/serve.env" ] || { printf 'GBRAIN_ADMIN_BOOTSTRAP_TOKEN=%s\nGBRAIN_PUBLIC_URL=http://127.0.0.1:%s\n' "$(openssl rand -hex 32)" "$GBRAIN_HTTP_PORT" > "$GBRAIN_SECRETS/serve.env"; say "generated the admin bootstrap token"; }
chown "$OWN" "$GBRAIN_SECRETS"/*.env; chmod 600 "$GBRAIN_SECRETS"/*.env
umask 022

# ---------------------------------------------------------------- scripts, nginx sources, compose, policy
say "scripts and config"
restart_serve=0
for f in "$HERE"/bin/* "$HERE/contrib/gbrain-monitor.sh"; do
  install_if_changed "$f" "$GBRAIN_BIN_DIR/$(basename "$f")" 0750 "$OWN" || true
done
for f in "$HERE"/nginx/*; do install_if_changed "$f" "$GBRAIN_ROOT/nginx/$(basename "$f")" 0640 "$OWN" || true; done
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
render_all "$tmp"
pg_changed=0
install_if_changed "$tmp/compose.yml" "$GBRAIN_ROOT/compose.yml" 0640 "$OWN" && pg_changed=1
if [ ! -f "$GBRAIN_INBOX_POLICY" ]; then
  install -m0640 -o "$GBRAIN_USER" -g "$GROUP" "$HERE/inbox-policy.conf.example" "$GBRAIN_INBOX_POLICY"
  say "installed an example upload policy: edit $GBRAIN_INBOX_POLICY"
fi

# ---------------------------------------------------------------- systemd units, logrotate, fail2ban
say "systemd units"
for f in "$tmp"/systemd/*; do
  if install_if_changed "$f" "/etc/systemd/system/$(basename "$f")" 0644; then
    case "$(basename "$f")" in gbrain.service) restart_serve=1 ;; esac
  fi
done
systemctl daemon-reload
install_if_changed "$tmp/logrotate-gbrain" /etc/logrotate.d/gbrain 0644 || true

if [ "$WITH_F2B" = 1 ] || command -v fail2ban-client >/dev/null; then
  install -d /etc/fail2ban/filter.d /etc/fail2ban/jail.d
  [ -d /var/log/nginx ] || install -d -m0755 /var/log/nginx
  [ -f /var/log/nginx/gbrain-access.log ] || install -m0640 -o root -g adm /dev/null /var/log/nginx/gbrain-access.log
  f2b=0
  install_if_changed "$HERE/fail2ban/gbrain-auth.filter.conf" /etc/fail2ban/filter.d/gbrain-auth.conf 0644 && f2b=1
  install_if_changed "$tmp/fail2ban/gbrain.local" /etc/fail2ban/jail.d/gbrain.local 0644 && f2b=1
  if ! command -v fail2ban-client >/dev/null; then
    say "installing fail2ban (note: on Debian/Ubuntu the package also enables its sshd jail)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban >/dev/null
  elif [ "$f2b" = 1 ]; then
    fail2ban-client reload >/dev/null 2>&1 || systemctl restart fail2ban
  fi
else
  say "fail2ban not installed: front doors will have no ban-after-failures (re-run with --with-fail2ban)"
fi

# ---------------------------------------------------------------- upload inbox (capped loop image on the data disk)
if [ ! -f "$GBRAIN_INBOX_IMG" ]; then
  say "creating the $GBRAIN_INBOX_SIZE inbox image"
  fallocate -l "$GBRAIN_INBOX_SIZE" "$GBRAIN_INBOX_IMG"
  chmod 600 "$GBRAIN_INBOX_IMG"
  mkfs.ext4 -q -m 0 -E nodiscard -L gbrain-inbox "$GBRAIN_INBOX_IMG"   # nodiscard keeps the space reserved
fi
if ! findmnt -n "$GBRAIN_INBOX" >/dev/null; then
  if [ ! -d "$GBRAIN_INBOX" ]; then install -d -m0750 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_INBOX"; fi
  [ -z "$(ls -A "$GBRAIN_INBOX")" ] || die "$GBRAIN_INBOX is not empty and not a mount: move its contents away first"
  chattr +i "$GBRAIN_INBOX" 2>/dev/null || true      # writes fail while unmounted
fi
systemctl enable "$INBOX_UNIT" >/dev/null 2>&1
if [ "$START" = 1 ]; then
  systemctl start "$INBOX_UNIT"
  chown "$OWN" "$GBRAIN_INBOX"; chmod 0750 "$GBRAIN_INBOX"
  [ ! -d "$GBRAIN_INBOX/lost+found" ] || rmdir "$GBRAIN_INBOX/lost+found" 2>/dev/null || true
  # one upload directory per person named in the policy
  sed -e 's/#.*//' "$GBRAIN_INBOX_POLICY" | awk -F: 'NF>1 {gsub(/[[:space:]]/, "", $1); if ($1 ~ /^[a-z0-9][a-z0-9_-]*$/) print $1}' |
    while read -r person; do install -d -m0750 -o "$GBRAIN_USER" -g "$GROUP" "$GBRAIN_INBOX/$person"; done
fi

# ---------------------------------------------------------------- bun + gbrain
as_user() { sudo -u "$GBRAIN_USER" -H env GBRAIN_HOME="$GBRAIN_HOME" PATH="$GBRAIN_BUN_BIN:/usr/local/bin:/usr/bin:/bin" "$@"; }
if [ ! -x "$GBRAIN_BUN_BIN/bun" ]; then
  [ "$GBRAIN_BUN_BIN" = "$USER_HOME/.bun/bin" ] || die "no bun at $GBRAIN_BUN_BIN: install Bun there or fix GBRAIN_BUN_BIN"
  say "installing Bun for $GBRAIN_USER"
  as_user bash -c 'curl -fsSL https://bun.sh/install | bash' >/dev/null
fi
if [ ! -x "$GBRAIN_EXE" ]; then
  say "installing gbrain ($GBRAIN_REF)"       # never the unrelated npm package named gbrain
  as_user bun install -g "github:garrytan/gbrain#$GBRAIN_REF" >/dev/null
fi
say "gbrain $(as_user "$GBRAIN_EXE" --version 2>/dev/null | awk '{print $NF}')"

[ "$START" = 1 ] || { say "installed (--no-start): nothing was started"; date -Is > "$MARK"; exit 0; }

readlink -f "$HERE/.." > "$GBRAIN_ETC/.source"      # move-data.sh re-runs this installer from here

# ---------------------------------------------------------------- Postgres
say "Postgres"
systemctl enable gbrain-pg.service >/dev/null 2>&1
if [ "$pg_changed" = 1 ] || [ "$(docker inspect -f '{{.State.Health.Status}}' gbrain-pg 2>/dev/null)" != healthy ]; then
  systemctl restart gbrain-pg.service      # compose up -d --wait: recreates the container if its config changed
  restart_serve=1
else
  systemctl start gbrain-pg.service
fi

# ---------------------------------------------------------------- first-time gbrain init
if [ ! -f "$GBRAIN_HOME/.gbrain/config.json" ]; then
  say "initialising the brain (keyword-only: no embeddings, nothing leaves this server)"
  ( set -a; . "$GBRAIN_SECRETS/db.env"; set +a
    as_user "$GBRAIN_EXE" init --url "postgres://gbrain:${GBRAIN_DB_PASSWORD}@127.0.0.1:${GBRAIN_PG_PORT}/gbrain" \
      --no-embedding --non-interactive --content-root "$GBRAIN_ROOT/repos" --no-git --json > "$GBRAIN_LOG_DIR/init.log" 2>&1 ) \
    || die "gbrain init failed: see $GBRAIN_LOG_DIR/init.log"
  as_user "$GBRAIN_EXE" apply-migrations --yes --no-autopilot-install > "$GBRAIN_LOG_DIR/apply-migrations.log" 2>&1 || true
  as_user "$GBRAIN_EXE" config set search.mode conservative >/dev/null
  as_user "$GBRAIN_EXE" config set memory.auto_writeback off >/dev/null 2>&1   # shared brain: explicit saves only
  as_user "$GBRAIN_EXE" sources unfederate default >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- services
say "services"
systemctl enable gbrain.service gbrain-ingest.timer gbrain-backup.timer >/dev/null 2>&1
if [ "$restart_serve" = 1 ] || ! systemctl is-active -q gbrain.service; then systemctl restart gbrain.service; fi
systemctl start gbrain-ingest.timer gbrain-backup.timer
date -Is > "$MARK"; chown "$OWN" "$MARK"

for i in $(seq 1 20); do
  [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GBRAIN_HTTP_PORT/health")" = 200 ] && break; sleep 2
done
if "$GBRAIN_BIN_DIR/gbrain-health.sh"; then say "installed and healthy"; else say "installed, but the health check reports problems (above)"; fi
cat <<EOF

Next steps (docs/server.md):
  1. sources and tokens   docs/server.md, section 3
  2. upload policy        $GBRAIN_INBOX_POLICY
  3. a front door         sudo $GBRAIN_BIN_DIR/enable-frontdoor.sh tailscale | wireguard <ip> | public <host>
  4. collaborators        python3 scripts/build_agent_setup.py --person <name> ...   (docs/server.md, section 6)
EOF
