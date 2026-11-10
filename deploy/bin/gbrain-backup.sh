#!/usr/bin/env bash
# gbrain-backup.sh — nightly logical backup of the GBrain Postgres + config.
#   $GBRAIN_DATA_DIR/backups/daily/   gbrain-<date>.dump (pg_dump -Fc) + gbrain-home-<date>.tgz
#   $GBRAIN_DATA_DIR/backups/weekly/  Sunday copies
# Retention and the optional offsite rsync target come from /etc/gbrain/gbrain.conf
# (GBRAIN_BACKUP_KEEP_DAILY / _WEEKLY, GBRAIN_OFFSITE_RSYNC). Secrets are NOT in the backup:
# keep secrets/ (DB password, tokens, bootstrap token) in your password manager.
#
# Restore:  systemctl stop gbrain gbrain-ingest.timer
#           docker exec -i gbrain-pg pg_restore -U gbrain -d gbrain --clean --if-exists < <file>.dump
#           systemctl start gbrain gbrain-ingest.timer
set -euo pipefail
umask 077
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"

ROOT="$GBRAIN_BACKUP_DIR"
d="$(date +%F)"
mkdir -p "$ROOT/daily" "$ROOT/weekly"
log() { printf '%s %s\n' "$(date -Is)" "$*"; }

dump="$ROOT/daily/gbrain-$d.dump"
docker exec gbrain-pg pg_dump -U gbrain -d gbrain -Fc -Z 6 > "$dump.part"
# A dump that pg_restore cannot list is not a backup.
docker exec -i gbrain-pg pg_restore -l < "$dump.part" > /dev/null
mv "$dump.part" "$dump"
tar -czf "$ROOT/daily/gbrain-home-$d.tgz" -C "$GBRAIN_ROOT" \
    --exclude='home/.gbrain/run' --exclude='home/.gbrain/.locks' home etc compose.yml
log "daily ok: $(du -h "$dump" | cut -f1) $dump"

prune() { # <dir> <keep> : keep the newest <keep> dumps (+ their config tarballs)
  local f
  find "$1" -maxdepth 1 -name 'gbrain-[0-9]*.dump' -printf '%T@ %p\n' | sort -rn | tail -n +"$(( $2 + 1 ))" |
    while read -r _ f; do
      rm -f "$f" "$1/gbrain-home-$(basename "$f" .dump | sed 's/^gbrain-//').tgz"
    done
}

offsite_rc=0
if [ "$(date +%u)" = 7 ] || [ "${FORCE_WEEKLY:-0}" = 1 ]; then
  cp -f "$dump" "$ROOT/weekly/"
  cp -f "$ROOT/daily/gbrain-home-$d.tgz" "$ROOT/weekly/"
  log "weekly copy ok"
  prune "$ROOT/weekly" "$GBRAIN_BACKUP_KEEP_WEEKLY"
  if [ -n "$GBRAIN_OFFSITE_RSYNC" ]; then
    if rsync -a --delete -e 'ssh -o BatchMode=yes -o ConnectTimeout=20' "$ROOT/weekly/" "$GBRAIN_OFFSITE_RSYNC"; then
      log "offsite ok -> $GBRAIN_OFFSITE_RSYNC"
      date +%s > "$ROOT/.last_offsite_success"
    else
      offsite_rc=1
      log "OFFSITE FAILED -> $GBRAIN_OFFSITE_RSYNC (local backup is fine)"
    fi
  else
    log "offsite skipped: GBRAIN_OFFSITE_RSYNC not set"
  fi
fi

prune "$ROOT/daily" "$GBRAIN_BACKUP_KEEP_DAILY"
date +%s > "$ROOT/.last_success"       # the local dump is good
exit "$offsite_rc"                     # ...but a failed offsite copy fails the unit, so it gets noticed
