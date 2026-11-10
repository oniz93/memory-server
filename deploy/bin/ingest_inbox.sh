#!/usr/bin/env bash
# ingest_inbox.sh — server-side timer: ingest staged session logs into GBrain, per source.
#
# Inbox layout (people only ever write into their own <person>/ dir):
#
#   $INBOX/<person>/<source-id>/<harness>/...      e.g. alice/research-alpha/claude-code/<uuid>.jsonl
#   $INBOX/<person>/<source-id>/*.db                Hermes slices may sit directly in the source dir
#
#   <harness> = hermes | claude-code | codex | grok | openclaw | chatgpt | claude-export | auto
#               (anything else / no harness dir: format from file name, else gbrain auto-detects)
#
# Policy: $POLICY lists which sources each person may stage into ("person: src1 src2", # comments).
# A file staged under a source the person is not allowed is moved to .rejected/ and never ingested.
#
# Hostile-input rules (the inbox is written by other people):
#   - paths are NUL-delimited end to end; names with control characters are rejected;
#   - symlinks are never followed: a symlinked person/source dir or any symlink inside is moved
#     (as a link) to .rejected/;
#   - every path is realpath-checked to sit inside $INBOX/<person>/<source>/ before it is passed to
#     gbrain or moved.
#
# Lifecycle of a file:  staged -> (ready: not a dotfile, untouched for $SETTLE_SECS) -> ingest
#   imported/filtered -> .done/<date>/<person>/<source>/...   (pruned after $KEEP_DAYS)
#   pending (gbrain still publishing) -> left in place, picked up by a later run
#   failed  -> left in place, retried; after $MAX_ATTEMPTS failures -> .failed/<date>/...
#
# Env (defaults in brackets):
# Paths and limits come from /etc/gbrain/gbrain.conf via gbrain-env.sh (GBRAIN_CONF overrides the
# location). Extra knobs: GBRAIN_SETTLE_SECS [120], GBRAIN_MAX_ATTEMPTS [3], DRY_RUN=1 (pass
# --dry-run to gbrain and move nothing). Tests override GBRAIN_INBOX / GBRAIN_INBOX_POLICY /
# GBRAIN_LOG_DIR / GBRAIN_BIN.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"

INBOX="$GBRAIN_INBOX"
POLICY="$GBRAIN_INBOX_POLICY"
LOG_DIR="$GBRAIN_LOG_DIR"
KEEP_DAYS="$GBRAIN_DONE_KEEP_DAYS"
DONE_MAX_MB="$GBRAIN_DONE_MAX_MB"      # .done is only a safety copy; hourly syncs would fill the inbox
SETTLE_SECS="${GBRAIN_SETTLE_SECS:-120}"
MAX_ATTEMPTS="${GBRAIN_MAX_ATTEMPTS:-3}"
DRY_RUN="${DRY_RUN:-0}"
GBRAIN="$GBRAIN_EXE"

[ -x "$GBRAIN" ] || { echo "gbrain not found at $GBRAIN (GBRAIN_BUN_BIN in $GBRAIN_CONF)" >&2; exit 1; }
[ -r "$POLICY" ] || { echo "policy file missing: $POLICY" >&2; exit 1; }
mkdir -p "$LOG_DIR" "$INBOX/.done" "$INBOX/.failed" "$INBOX/.rejected" "$INBOX/.attempts"
INBOX="$(realpath -e "$INBOX")"

INGEST_LOG="$LOG_DIR/ingest.jsonl"
today="$(date +%F)"
status=0

# Log a path safely (control characters shown as '?').
shown() { printf '%s' "${1#"$INBOX"/}" | tr '[:cntrl:]' '?'; }
log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# One run at a time (the timer can fire while a big slice is still ingesting).
exec 9>"$INBOX/.lock"
flock -n 9 || { log "previous run still active; skipping"; exit 0; }

# allowed <person> <source> -> 0 if the policy grants it (comments ignored).
allowed() {
  awk -v p="$1" -v s="$2" '
    { sub(/#.*/, "") }
    /^[[:space:]]*$/ { next }
    { sub(/:/, " "); if ($1 == p) for (i = 2; i <= NF; i++) if ($i == s) ok = 1 }
    END { exit ok ? 0 : 1 }' "$POLICY"
}

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }
has_cntrl()  { [[ "$1" == *[[:cntrl:]]* ]]; }

# inside <path> <root>: the fully resolved path is strictly under the resolved root.
inside() {
  local real root
  real="$(realpath -e -- "$1" 2>/dev/null)" || return 1
  root="$(realpath -e -- "$2" 2>/dev/null)" || return 1
  [[ "$real" == "$root"/* ]]
}

format_for() { # <harness-dir-name> <file>
  case "$1" in
    hermes|claude-code|codex|grok|openclaw|chatgpt|claude-export) echo "$1"; return ;;
  esac
  case "$2" in
    *.db) echo hermes ;;
    */chat_history.jsonl) echo grok ;;
    *) echo "" ;;   # let gbrain auto-detect
  esac
}

# move_under <root> <path> : move a file or a symlink (never its target) to <root>/<path rel. to INBOX>.
move_under() {
  local root="$1" f="$2" rel
  [[ "$f" == "$INBOX"/* ]] || { log "REFUSE move outside inbox: $(shown "$f")"; return 1; }
  rel="${f#"$INBOX"/}"
  mkdir -p -- "$root/$(dirname -- "$rel")"
  mv -fT -- "$f" "$root/$rel"
}

reject() { # <path> <reason>
  log "REJECT ($2) $(shown "$1")"
  [ "$DRY_RUN" = 1 ] || move_under "$INBOX/.rejected/$today" "$1" || true
}

attempt_key() { printf '%s' "$1" | sha256sum | cut -c1-32; }

note_failure() { # <file>
  local k n
  k="$INBOX/.attempts/$(attempt_key "$1")"
  n=$(( $(cat "$k" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$k"
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then
    move_under "$INBOX/.failed/$today" "$1" || true
    rm -f "$k"
    log "FAILED x$n, moved to .failed: $(shown "$1")"
  else
    log "failed attempt $n/$MAX_ATTEMPTS: $(shown "$1")"
  fi
}

now=$(date +%s)
ready() { # complete: not a dotfile (rsync temp), and untouched for SETTLE_SECS. Vanished -> not ready.
  local b m
  b="$(basename -- "$1")"
  [[ "$b" != .* ]] || return 1
  m="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  if [ $(( now - m )) -lt "$SETTLE_SECS" ]; then
    log "settling (modified <${SETTLE_SECS}s ago), next run: $(shown "$1")"
    return 1
  fi
}

# outcomes <json-file> <list-file> : print "<ok|pending|failed>\t<path>" per input file.
# Files gbrain did not report (it filters subagent/sidecar logs itself) count as ok.
outcomes() {
  python3 - "$1" "$2" <<'PY'
import json, sys
paths = open(sys.argv[2], encoding='utf-8', errors='surrogateescape').read().split('\0')
paths = [p for p in paths if p]
try:
    raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
    res = json.loads(raw[raw.index('{'):])
    by_path = {f.get('path'): f for f in res.get('files', [])}
except Exception:
    for p in paths: print(f'failed\t{p}')
    sys.exit(0)
for p in paths:
    f = by_path.get(p)
    if f is None: print(f'ok\t{p}'); continue
    sessions = f.get('sessions') or []
    if f.get('error') is not None or any(s.get('error') for s in sessions) or (f.get('drift') and not sessions):
        print(f'failed\t{p}')
    elif any(s.get('pending') for s in sessions):
        print(f'pending\t{p}')
    else:
        print(f'ok\t{p}')
PY
}

move_grok_sidecars() { # <person> <source> <chat_history path>: move contained sibling files to .done
  local sib
  for sib in "$(dirname -- "$3")"/*; do
    [ -f "$sib" ] && [ ! -L "$sib" ] || continue
    inside "$sib" "$INBOX/$1/$2" || continue
    move_under "$INBOX/.done/$today" "$sib" || true
  done
}

ingest_batch() { # <person> <source> <format> <files...>
  local person="$1" src="$2" fmt="$3"; shift 3
  [ "$#" -gt 0 ] || return 0
  local out list rc kind path n_ok=0 n_fail=0 n_pend=0
  out="$(mktemp)"; list="$(mktemp)"
  printf '%s\0' "$@" > "$list"
  local args=(transcripts ingest "$@" --source-id "$src" --since last --json)
  [ -n "$fmt" ] && args+=(--format "$fmt")
  [ "$DRY_RUN" = 1 ] && args+=(--dry-run)
  log "ingest $person -> $src (${fmt:-auto}): $# file(s)"
  if "$GBRAIN" "${args[@]}" >"$out" 2>"$LOG_DIR/ingest.last.err"; then rc=0; else rc=$?; fi
  printf '{"ts":"%s","person":"%s","source":"%s","format":"%s","files":%d,"rc":%d,"result":%s}\n' \
    "$(date -Is)" "$person" "$src" "${fmt:-auto}" "$#" "$rc" \
    "$(python3 -c 'import json,sys
s=sys.stdin.read()
try: print(json.dumps(json.loads(s[s.index("{"):])))
except Exception: print(json.dumps({"unparsed": s[-2000:]}))' < "$out")" >> "$INGEST_LOG"
  while IFS=$'\t' read -r kind path; do
    [ -n "$path" ] || continue
    case "$kind" in
      ok)      n_ok=$((n_ok+1))
               [ "$DRY_RUN" = 1 ] || { move_under "$INBOX/.done/$today" "$path" || true
                                      rm -f "$INBOX/.attempts/$(attempt_key "$path")"
                                      [ "$fmt" = grok ] && move_grok_sidecars "$person" "$src" "$path"; } ;;
      pending) n_pend=$((n_pend+1)); log "pending (left for next run): $(shown "$path")" ;;
      *)       n_fail=$((n_fail+1)); status=1; [ "$DRY_RUN" = 1 ] || note_failure "$path" ;;
    esac
  done < <(outcomes "$out" "$list")
  rm -f "$out" "$list"
  log "done $person -> $src: ok=$n_ok pending=$n_pend failed=$n_fail (gbrain rc=$rc)"
}

# Walk one source dir: collect ready, contained regular files per format; quarantine anything odd.
scan_source() { # <person> <src> <src-dir-without-slash>
  local person="$1" src="$2" dir="$3" f rel harness fmt gdir
  # Groups live in NUL-delimited files: bash strings cannot hold NUL bytes.
  gdir="$(mktemp -d)"
  while IFS= read -r -d '' f; do
    if has_cntrl "$f"; then reject "$f" "control character in name"; continue; fi
    if [ -L "$f" ]; then reject "$f" "symlink"; continue; fi
    [ -f "$f" ] || continue
    if ! inside "$f" "$dir"; then reject "$f" "resolves outside its source dir"; continue; fi
    case "$f" in *.db|*.jsonl|*.json) ;; *) continue ;; esac
    ready "$f" || continue
    rel="${f#"$dir"/}"; harness="${rel%%/*}"; [ "$harness" = "$rel" ] && harness=""
    fmt="$(format_for "$harness" "$f")"
    # Grok: only chat_history.jsonl is a session. Its sidecars (summary.json, ...) must stay next to
    # it for gbrain to read, and move to .done with it; passed explicitly they count as drift.
    if [ "$fmt" = grok ] && [ "$(basename -- "$f")" != chat_history.jsonl ]; then continue; fi
    printf '%s\0' "$f" >> "$gdir/${fmt:-auto}"
  done < <(find -P "$dir" -mindepth 1 \( -type f -o -type l \) -print0)

  local gfile key files
  for gfile in "$gdir"/*; do
    [ -f "$gfile" ] || continue
    key="$(basename -- "$gfile")"
    mapfile -d '' -t files < "$gfile"
    ingest_batch "$person" "$src" "$([ "$key" = auto ] || echo "$key")" "${files[@]}"
  done
  rm -rf -- "$gdir"
}

shopt -s nullglob
for person_dir in "$INBOX"/*; do
  person="$(basename -- "$person_dir")"
  valid_name "$person" || continue             # skips .done/.failed/... and odd names
  if [ -L "$person_dir" ]; then reject "$person_dir" "symlinked person dir"; continue; fi
  [ -d "$person_dir" ] || continue

  for entry in "$person_dir"/*; do
    name="$(basename -- "$entry")"
    if [ -L "$entry" ]; then reject "$entry" "symlink"; continue; fi
    if [ -f "$entry" ]; then
      ready "$entry" && reject "$entry" "no source dir"
      continue
    fi
    [ -d "$entry" ] || continue
    if ! valid_name "$name" || ! allowed "$person" "$name"; then
      # Quarantine the contents (never following links) of a source the person may not use.
      while IFS= read -r -d '' f; do
        if [ -L "$f" ] || has_cntrl "$f" || ready "$f"; then
          reject "$f" "$person not allowed to stage into '$(shown "$name")'"
        fi
      done < <(find -P "$entry" -mindepth 1 \( -type f -o -type l \) -print0)
      continue
    fi
    scan_source "$person" "$name" "$entry"
  done
done

# Prune processed / rejected / failed copies older than KEEP_DAYS, and empty staging dirs.
for d in .done .rejected .failed; do
  find -P "$INBOX/$d" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec rm -rf -- {} + 2>/dev/null || true
done
find -P "$INBOX" -mindepth 3 -type d -empty -mmin +60 -not -path "$INBOX/.*" -delete 2>/dev/null || true

# Cap .done by size: delete the oldest processed copies (by move time = ctime) until under the cap.
find -P "$INBOX/.done" -type f -printf '%C@\t%s\t%p\0' 2>/dev/null | python3 -c '
import os, sys
cap = int(sys.argv[1]) * 1024 * 1024
rows = []
for rec in sys.stdin.buffer.read().split(b"\0"):
    if rec:
        c, n, p = rec.split(b"\t", 2)
        rows.append((float(c), int(n), p))
total = sum(n for _, n, _ in rows)
gone = 0
for c, n, p in sorted(rows):
    if total <= cap:
        break
    try:
        os.unlink(p); total -= n; gone += 1
    except OSError:
        pass
if gone:
    print(f"pruned {gone} oldest .done file(s) to stay under {sys.argv[1]} MB")
' "$DONE_MAX_MB" || true
find -P "$INBOX/.done" -mindepth 1 -type d -empty -delete 2>/dev/null || true

exit "$status"
