#!/usr/bin/env bash
# gbrain-health.sh — one-shot health check of the GBrain server. Exit 0 = healthy, 1 = problems.
#
#   gbrain-health.sh              human-readable report
#   gbrain-health.sh --porcelain  one problem per line: <key>TAB<level>TAB<message>  (level: crit|warn)
#
# Checks: data disk mounted, Postgres container healthy, MCP server answering, memory near the
# caps, backup freshness (and offsite, when configured), failed uploads, inbox capacity.
# Wire it into whatever alerting you have (see deploy/contrib/gbrain-monitor.sh for a hook into a
# bash monitor script, or run it from cron and mail the output).
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"

PORCELAIN=0; [ "${1:-}" = --porcelain ] && PORCELAIN=1
HEALTH_URL="${GBRAIN_HEALTH_URL:-http://127.0.0.1:$GBRAIN_HTTP_PORT/health}"
SERVE_WARN_MB="${GBRAIN_SERVE_MEM_WARN_MB:-$(( GBRAIN_SERVE_MEM_MB * 5 / 6 ))}"
PG_WARN_MB="${GBRAIN_PG_MEM_WARN_MB:-$(( GBRAIN_PG_MEM_MB * 7 / 8 ))}"
BACKUP_MAX_AGE_H="${GBRAIN_BACKUP_MAX_AGE_H:-36}"
INBOX_WARN_PCT="${GBRAIN_INBOX_WARN_PCT:-80}"
problems=0
problem() { # <key> <level> <message>
  problems=$((problems + 1))
  if [ "$PORCELAIN" = 1 ]; then printf '%s\t%s\t%s\n' "$1" "$2" "$3"; else printf '[%s] %s: %s\n' "$2" "$1" "$3"; fi
}

# 1. data disk
if ! [ -d "$GBRAIN_PG_DIR" ]; then
  problem data_missing crit "data dir $GBRAIN_DATA_DIR is not available (disk not mounted?)"
fi

# 2. Postgres container
if [ "$(docker inspect -f '{{.State.Health.Status}}' gbrain-pg 2>/dev/null)" != healthy ]; then
  problem pg_down crit "container gbrain-pg is not healthy"
fi

# 3. MCP server
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)" || true
code="${code:-000}"
if ! systemctl is-active -q gbrain.service || [ "$code" != 200 ]; then
  problem serve_down crit "gbrain.service $(systemctl is-active gbrain.service 2>/dev/null), /health HTTP $code"
fi

# 4. memory (both have hard caps; warn before they hit them)
mem_b="$(systemctl show gbrain.service -p MemoryCurrent --value 2>/dev/null)"
if [[ "$mem_b" =~ ^[0-9]+$ ]] && [ $(( mem_b / 1048576 )) -ge "$SERVE_WARN_MB" ]; then
  problem serve_mem warn "gbrain.service at $(( mem_b / 1048576 )) MB (cap $GBRAIN_SERVE_MEM_MB MB)"
fi
pg_mem="$(docker stats --no-stream --format '{{.MemUsage}}' gbrain-pg 2>/dev/null | awk '{
    v=$1; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v);
    if (u=="GiB") v*=1024; else if (u=="KiB") v/=1024; printf "%d", v }')"
if [[ "$pg_mem" =~ ^[0-9]+$ ]] && [ "$pg_mem" -ge "$PG_WARN_MB" ]; then
  problem pg_mem warn "Postgres at $pg_mem MB (cap $GBRAIN_PG_MEM_MB MB)"
fi

# 5. backups
now="$(date +%s)"
last="$(cat "$GBRAIN_BACKUP_DIR/.last_success" 2>/dev/null || echo 0)"
age=$(( (now - last) / 3600 ))
if [ "$age" -ge "$BACKUP_MAX_AGE_H" ]; then
  problem backup_stale warn "last good pg_dump ${age} h ago (see $GBRAIN_LOG_DIR/backup.log)"
fi
if [ -n "$GBRAIN_OFFSITE_RSYNC" ]; then
  off="$(cat "$GBRAIN_BACKUP_DIR/.last_offsite_success" 2>/dev/null || echo 0)"
  if [ $(( (now - off) / 86400 )) -ge 9 ]; then
    problem offsite_stale warn "no successful offsite backup copy for $(( (now - off) / 86400 )) days"
  fi
fi

# 6. ingest: files that exhausted their retries today, or a failed timer run
failed="$(find "$GBRAIN_INBOX/.failed" -type f -newermt "$(date +%F)" 2>/dev/null | wc -l)"
if [ "$failed" -gt 0 ] || systemctl is-failed -q gbrain-ingest.service; then
  problem ingest_failed warn "$failed upload(s) moved to inbox/.failed today; gbrain-ingest.service $(systemctl is-failed gbrain-ingest.service 2>/dev/null)"
fi

# 7. inbox capacity (uploads stop at 100%; also catches a missing mount)
if ! findmnt -n "$GBRAIN_INBOX" >/dev/null 2>&1; then
  problem inbox_full crit "$GBRAIN_INBOX is not mounted"
else
  pct="$(df --output=pcent "$GBRAIN_INBOX" 2>/dev/null | tail -1 | tr -dc 0-9)"
  if [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -ge "$INBOX_WARN_PCT" ]; then
    problem inbox_full warn "${pct}% of the $GBRAIN_INBOX_SIZE inbox used (see inbox/.done, .failed)"
  fi
fi

[ "$PORCELAIN" = 1 ] || [ "$problems" -gt 0 ] || echo "gbrain: healthy"
[ "$problems" -eq 0 ]
