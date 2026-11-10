# gbrain-monitor.sh — example hook: feed gbrain-health.sh into an existing bash monitoring script.
# Sourced, not executed. The host script must provide:
#   telegram "<html text>"                 send an alert (any notifier works: rename as needed)
#   cooldown_check <key> <minutes>         return 0 when this alert may fire now
#   reset_cooldown <key>                   forget the cooldown once the problem is gone
#   log "<text>"                           and the variables PROBLEM / COOLDOWN_MINUTES
#
# In the host script:
#   [ -r /srv/gbrain/bin/gbrain-monitor.sh ] && . /srv/gbrain/bin/gbrain-monitor.sh
#   declare -F check_gbrain >/dev/null && check_gbrain && ALERT_SENT=true
# Returns 0 when at least one alert was sent (the convention of the host script it was written for).

_GBRAIN_HEALTH="${GBRAIN_HEALTH_CMD:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/gbrain-health.sh}"
_GBRAIN_KEYS="data_missing pg_down serve_down serve_mem pg_mem backup_stale offsite_stale ingest_failed inbox_full"

check_gbrain() {
  local changed=false seen=" " key level msg icon k
  while IFS=$'\t' read -r key level msg; do
    [ -n "$key" ] || continue
    seen+="$key "
    PROBLEM=true
    if cooldown_check "gbrain_$key" "${COOLDOWN_MINUTES:-60}"; then
      icon="🟡"; [ "$level" = crit ] && icon="🔴"
      log "ALERT: gbrain $key: $msg"
      telegram "$icon <b>GBRAIN ($(hostname -s)):</b> $msg"
      changed=true
    fi
  done < <("$_GBRAIN_HEALTH" --porcelain 2>/dev/null)
  for k in $_GBRAIN_KEYS; do
    [[ "$seen" == *" $k "* ]] || reset_cooldown "gbrain_$k"
  done
  [ "$changed" = true ]
}
