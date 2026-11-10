# gbrain-env.sh — sourced by every server script: loads the site config and derives all paths.
#   . "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"
# Override the config location with GBRAIN_CONF (tests do). Values already in the environment
# win over the file only for the test-only overrides listed at the bottom.

GBRAIN_CONF="${GBRAIN_CONF:-/etc/gbrain/gbrain.conf}"
if [ -r "$GBRAIN_CONF" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$GBRAIN_CONF"
  set +a
elif [ "${GBRAIN_CONF_OPTIONAL:-0}" != 1 ]; then
  echo "gbrain: config not found: $GBRAIN_CONF (copy deploy/gbrain.conf.example there)" >&2
  exit 1
fi

: "${GBRAIN_USER:=gbrain}"
: "${GBRAIN_ROOT:=/srv/gbrain}"
: "${GBRAIN_DATA_DIR:=$GBRAIN_ROOT/data}"
: "${GBRAIN_BUN_BIN:=/home/$GBRAIN_USER/.bun/bin}"
: "${GBRAIN_REF:=stable}"
: "${GBRAIN_HTTP_PORT:=3131}"
: "${GBRAIN_PG_PORT:=5433}"
: "${GBRAIN_SHIM_PORT:=4010}"
: "${GBRAIN_TUNNEL_PORT:=3132}"
: "${GBRAIN_INBOX_SIZE:=2G}"
: "${GBRAIN_DONE_KEEP_DAYS:=30}"
: "${GBRAIN_DONE_MAX_MB:=600}"
: "${GBRAIN_PG_MEM_MB:=512}"
: "${GBRAIN_SERVE_MEM_MB:=768}"
: "${GBRAIN_BACKUP_KEEP_DAILY:=7}"
: "${GBRAIN_BACKUP_KEEP_WEEKLY:=4}"
: "${GBRAIN_OFFSITE_RSYNC:=}"

# Derived paths (single source of truth for the layout).
GBRAIN_HOME="$GBRAIN_ROOT/home"                 # gbrain's own config/audit dir
GBRAIN_BIN_DIR="$GBRAIN_ROOT/bin"
GBRAIN_SECRETS="$GBRAIN_ROOT/secrets"
GBRAIN_ETC="$GBRAIN_ROOT/etc"
GBRAIN_INBOX="${GBRAIN_INBOX:-$GBRAIN_ROOT/inbox}"                       # mountpoint of the image
GBRAIN_INBOX_POLICY="${GBRAIN_INBOX_POLICY:-$GBRAIN_ETC/inbox-policy.conf}"
GBRAIN_INBOX_IMG="$GBRAIN_DATA_DIR/inbox.img"
GBRAIN_PG_DIR="$GBRAIN_DATA_DIR/pg"
GBRAIN_BACKUP_DIR="$GBRAIN_DATA_DIR/backups"
GBRAIN_LOG_DIR="${GBRAIN_LOG_DIR:-$GBRAIN_DATA_DIR/logs}"
GBRAIN_EXE="${GBRAIN_BIN:-$GBRAIN_BUN_BIN/gbrain}"
GBRAIN_COMPOSE=(docker compose -f "$GBRAIN_ROOT/compose.yml" --env-file "$GBRAIN_SECRETS/db.env")

export GBRAIN_HOME
export PATH="$GBRAIN_BUN_BIN:$PATH"
