#!/usr/bin/env bash
# move-data.sh — relocate GBrain's data (Postgres, backups, logs, inbox image) to another disk.
#
#   sudo move-data.sh <new-data-dir> [--yes]      e.g. sudo move-data.sh /mnt/volume1/gbrain
#
# What it does, in order (the old copy is kept until you delete it yourself):
#   1. checks the target (mounted filesystem, enough free space, not inside the current data dir)
#   2. takes a fresh backup and records row counts
#   3. stops ingest, the MCP server, the LLM shim, the inbox mount and Postgres
#   4. copies pg/ backups/ logs/ inbox.img with rsync (ownership and permissions preserved)
#   5. rewrites GBRAIN_DATA_DIR in the config and re-renders units + compose via install.sh
#   6. starts everything from the new location and verifies health and row counts
#   7. on any failure before step 5 finishes: restarts from the OLD location, config untouched
# Needs the repo checkout that install.sh was run from (GBRAIN_SRC, default: recorded at install).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"

NEW="${1:-}"; YES=0; [ "${2:-}" = --yes ] && YES=1
die() { echo "error: $*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }
[ "$(id -u)" = 0 ] || die "run with sudo"
[[ "$NEW" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "usage: move-data.sh <absolute-new-data-dir> [--yes]"
NEW="${NEW%/}"
OLD="$GBRAIN_DATA_DIR"
[ "$NEW" != "$OLD" ] || die "data is already in $OLD"
case "$NEW/" in "$OLD"/*) die "the new dir must not be inside the current data dir" ;; esac
SRC="${GBRAIN_SRC:-$(cat "$GBRAIN_ETC/.source" 2>/dev/null || true)}"
[ -x "$SRC/deploy/install.sh" ] || die "repo checkout not found (set GBRAIN_SRC=/path/to/checkout)"

parent="$(dirname "$NEW")"
[ -d "$parent" ] || die "$parent does not exist"
ITEMS=(pg backups logs inbox.img)
need_kb=0
for i in "${ITEMS[@]}"; do [ -e "$OLD/$i" ] && need_kb=$(( need_kb + $(du -sk "$OLD/$i" | cut -f1) )); done
free_kb="$(df -k --output=avail "$parent" | tail -1)"
[ "$free_kb" -gt $(( need_kb + 1048576 )) ] || die "not enough space in $parent: need $(( need_kb / 1024 )) MB + 1 GB headroom, have $(( free_kb / 1024 )) MB"
[ ! -e "$NEW/pg" ] || die "$NEW/pg already exists: refusing to overwrite a database"

say "move $(( need_kb / 1024 )) MB of GBrain data"
say "  from $OLD  ($(df -h --output=target "$OLD" | tail -1))"
say "  to   $NEW  ($(df -h --output=target "$parent" | tail -1), $(( free_kb / 1048576 )) GB free)"
if [ "$YES" != 1 ]; then
  read -r -p "Services will be down for a minute. Continue? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted"
fi

counts() { docker exec gbrain-pg psql -U gbrain -d gbrain -Atc \
  "select (select count(*) from pages)||' pages, '||(select count(*) from sources)||' sources, '||(select count(*) from access_tokens)||' tokens'"; }
say "fresh backup + row counts"
sudo -u "$GBRAIN_USER" "$GBRAIN_BIN_DIR/gbrain-backup.sh" >/dev/null
before="$(counts)"; say "  before: $before"

INBOX_UNIT="$(systemd-escape -p --suffix=mount "$GBRAIN_INBOX")"
shim_was="$(systemctl is-active gbrain-llm-shim.service 2>/dev/null || true)"
stop_all() {
  systemctl stop gbrain-ingest.timer gbrain-backup.timer gbrain-ingest.service 2>/dev/null || true
  systemctl stop gbrain.service gbrain-llm-shim.service 2>/dev/null || true
  systemctl stop "$INBOX_UNIT" 2>/dev/null || true
  "${GBRAIN_COMPOSE[@]}" stop >/dev/null 2>&1 || true
}
start_all() {
  systemctl restart gbrain-pg.service
  systemctl start "$INBOX_UNIT"
  systemctl restart gbrain.service
  [ "$shim_was" != active ] || systemctl start gbrain-llm-shim.service
  systemctl start gbrain-ingest.timer gbrain-backup.timer
}

stopped=0; switched=0
on_exit() { # any exit after the stop and before the switch: bring the old setup back up
  local rc=$?
  if [ "$stopped" = 1 ] && [ "$switched" = 0 ]; then
    echo "!! failed before the switch: restarting from the old location ($OLD); config unchanged" >&2
    start_all || true
  fi
  exit "$rc"
}
trap on_exit EXIT

say "stopping services"
stopped=1
stop_all
say "copying"
install -d -m0750 -o "$GBRAIN_USER" -g "$(id -gn "$GBRAIN_USER")" "$NEW"
for i in "${ITEMS[@]}"; do
  [ -e "$OLD/$i" ] || continue
  rsync -aHAX --numeric-ids "$OLD/$i" "$NEW/"
done
# second pass must find nothing left to copy
left="$(for i in "${ITEMS[@]}"; do [ -e "$OLD/$i" ] && rsync -aHAXn --numeric-ids --itemize-changes "$OLD/$i" "$NEW/"; done | grep -c '^[<>ch]' || true)"
[ "$left" = 0 ] || die "verification failed: $left item(s) differ after the copy"

say "switching the config to $NEW"
cp -p "$GBRAIN_CONF" "$GBRAIN_CONF.bak-$(date +%Y%m%d%H%M%S)"
if grep -q '^GBRAIN_DATA_DIR=' "$GBRAIN_CONF"; then
  sed -i "s#^GBRAIN_DATA_DIR=.*#GBRAIN_DATA_DIR=$NEW#" "$GBRAIN_CONF"
else
  echo "GBRAIN_DATA_DIR=$NEW" >> "$GBRAIN_CONF"
fi
switched=1
"$SRC/deploy/install.sh"            # re-renders compose + units for the new path and starts everything

after="$(counts)"; say "  after:  $after"
[ "$before" = "$after" ] || die "ROW COUNTS DIFFER (before: $before / after: $after). The old data is untouched in $OLD; restore the config backup and re-run install.sh to go back."
mounted_from="$(docker inspect gbrain-pg -f '{{range .Mounts}}{{.Source}}{{end}}')"
[ "$mounted_from" = "$NEW/pg" ] || die "Postgres is still mounted from $mounted_from"

stamp="moved-$(date +%Y%m%d)"
for i in "${ITEMS[@]}"; do [ -e "$OLD/$i" ] && mv "$OLD/$i" "$OLD/$i.$stamp"; done
say "done. Data now lives in $NEW."
say "The old copy was renamed to *.$stamp in $OLD. After a few days of normal operation, free the space:"
for i in "${ITEMS[@]}"; do [ -e "$OLD/$i.$stamp" ] && echo "      sudo rm -rf $OLD/$i.$stamp"; done
exit 0
