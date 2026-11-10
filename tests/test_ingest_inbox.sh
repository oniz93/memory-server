#!/usr/bin/env bash
# test_ingest_inbox.sh — behavioural tests for scripts/ingest_inbox.sh (run on a GNU/Linux host).
#   bash tests/test_ingest_inbox.sh [path/to/ingest_inbox.sh]
# Uses a fake gbrain that records its argv (NUL-separated) and emits gbrain-shaped JSON:
# a path whose basename contains BAD gets a file error, PENDING gets a pending session,
# exit 1 only when every file failed (like the real CLI).
set -uo pipefail
SCRIPT="$(realpath "${1:-$(dirname "$0")/../deploy/bin/ingest_inbox.sh}")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  PASS $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin"
cat > "$T/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FAKE_ARGS"; printf '\n' >> "$FAKE_ARGS.calls"
python3 - "$@" <<'PY'
import json, os, sys
paths = [a for a in sys.argv[1:] if a.startswith('/')]
files, allfail = [], bool(paths)
for p in paths:
    b = os.path.basename(p)
    if b == 'summary.json':   # real gbrain: an explicitly passed grok sidecar = drift, zero sessions
        files.append({"path": p, "drift": True, "sessions": []}); allfail = False; continue
    if 'BAD' in b:
        files.append({"path": p, "error": "parse failed", "sessions": [], "drift": False}); continue
    allfail = False
    s = {"sessionId": b, "harness": "codex", "baseSlug": "x/" + b}
    if 'PENDING' in b: s["pending"] = True
    files.append({"path": p, "sessions": [s], "drift": False})
print(json.dumps({"files": files, "sessionsErrored": sum(1 for f in files if "error" in f), "cleanScan": not any("error" in f for f in files)}))
sys.exit(1 if allfail else 0)
PY
EOF
# stat shim: simulate a file vanishing between find and stat for names containing VANISH.
cat > "$T/bin/stat" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *VANISH*) exit 1 ;; esac; done
exec /usr/bin/stat "$@"
EOF
chmod +x "$T/bin/gbrain" "$T/bin/stat"

setup() { # fresh sandbox per test
  rm -rf "$T/inbox" "$T/logs" "$T/outside" "$T/args"*; mkdir -p "$T/inbox" "$T/logs" "$T/outside"
  cat > "$T/policy" <<'EOF'
# test policy
owner:   research-alpha owner-private
alice: research-alpha   # later maybe: owner-private
bob: research-alpha
EOF
}
stage() { mkdir -p "$(dirname "$1")"; printf '{"type":"x"}\n' > "$1"; touch -d '-10 min' "$1"; }
run() {
  env PATH="$T/bin:$PATH" FAKE_ARGS="$T/args" GBRAIN_BIN="$T/bin/gbrain" GBRAIN_INBOX="$T/inbox" \
      GBRAIN_INBOX_POLICY="$T/policy" GBRAIN_LOG_DIR="$T/logs" GBRAIN_SETTLE_SECS=60 \
      GBRAIN_CONF="$T/none.conf" GBRAIN_CONF_OPTIONAL=1 GBRAIN_ROOT="$T/root" \
      bash "$SCRIPT" > "$T/run.out" 2>&1
  echo $? > "$T/rc"
}
args_outside_inbox() { # any absolute-path argv entry not under the sandbox inbox?
  [ -f "$T/args" ] || return 1
  tr '\0' '\n' < "$T/args" | grep '^/' | grep -qv "^$T/inbox/"
}
passed_to_gbrain() { [ -f "$T/args" ] && tr '\0' '\n' < "$T/args" | grep -qF "$1"; }

echo "T1 newline in an uploaded filename cannot inject paths"
setup; mkdir -p "$T/outside/secret"; printf 'private\n' > "$T/outside/secret/canary.jsonl"
stage "$T/inbox/alice/research-alpha/codex/a"$'\n'"$T/outside/secret"$'\n'"b.jsonl"
stage "$T/inbox/alice/research-alpha/codex/good.jsonl"
run
check "no gbrain argument outside the inbox" '! args_outside_inbox'
check "outside canary untouched" '[ -f "$T/outside/secret/canary.jsonl" ]'
check "good file still ingested" '[ -f "$T/inbox/.done/$(date +%F)/alice/research-alpha/codex/good.jsonl" ]'

echo "T2 symlinked source dir / subdir is never followed"
setup; mkdir -p "$T/outside/private" "$T/outside/homedir"
stage "$T/outside/private/owner-slice.jsonl"; stage "$T/outside/homedir/.ssh-like.jsonl"; stage "$T/outside/homedir/notes.txt"
mkdir -p "$T/inbox/alice"
ln -s "$T/outside/private" "$T/inbox/alice/research-alpha"     # allowed name -> outside
ln -s "$T/outside/homedir"    "$T/inbox/alice/x"                # disallowed name -> outside
mkdir -p "$T/inbox/bob/research-alpha"; ln -s "$T/outside/private" "$T/inbox/bob/research-alpha/codex"
run
check "nothing outside was passed to gbrain" '! args_outside_inbox'
check "outside private file untouched" '[ -f "$T/outside/private/owner-slice.jsonl" ]'
check "outside home files untouched" '[ -f "$T/outside/homedir/notes.txt" ] && [ -f "$T/outside/homedir/.ssh-like.jsonl" ]'

echo "T3 partially failed batch: only good files leave the inbox"
setup
for f in good1 BAD good2; do stage "$T/inbox/bob/research-alpha/codex/$f.jsonl"; done
stage "$T/inbox/bob/research-alpha/codex/PENDING.jsonl"
run
d="$T/inbox/.done/$(date +%F)/bob/research-alpha/codex"
check "good files moved to .done" '[ -f "$d/good1.jsonl" ] && [ -f "$d/good2.jsonl" ]'
check "failed file stays for retry" '[ -f "$T/inbox/bob/research-alpha/codex/BAD.jsonl" ]'
check "pending file stays for a later run" '[ -f "$T/inbox/bob/research-alpha/codex/PENDING.jsonl" ]'
check "run reports failure" '[ "$(cat "$T/rc")" != 0 ]'

echo "T4 a file vanishing mid-run does not abort the other people/sources"
setup
stage "$T/inbox/alice/research-alpha/codex/VANISH.jsonl"
stage "$T/inbox/bob/research-alpha/codex/after.jsonl"
run
check "later file still ingested" '[ -f "$T/inbox/.done/$(date +%F)/bob/research-alpha/codex/after.jsonl" ]'

echo "T5 a trailing comment in the policy grants nothing"
setup
stage "$T/inbox/alice/owner-private/codex/sneaky.jsonl"
run
check "not passed to gbrain" '! passed_to_gbrain sneaky.jsonl'
check "moved to .rejected" '[ -f "$T/inbox/.rejected/$(date +%F)/alice/owner-private/codex/sneaky.jsonl" ]'

echo "T6 regression: allowed path ingested, no-source and disallowed rejected, settling left alone"
setup
stage "$T/inbox/owner/owner-private/hermes/slice.db"
stage "$T/inbox/bob/stray.jsonl"
stage "$T/inbox/bob/owner-private/codex/nope.jsonl"
mkdir -p "$T/inbox/bob/research-alpha/codex"; printf 'x\n' > "$T/inbox/bob/research-alpha/codex/fresh.jsonl"
run
check "owner slice ingested into owner-private" '[ -f "$T/inbox/.done/$(date +%F)/owner/owner-private/hermes/slice.db" ] && tr "\0" "\n" < "$T/args" | grep -qx owner-private'
check "stray rejected" '[ -f "$T/inbox/.rejected/$(date +%F)/bob/stray.jsonl" ]'
check "disallowed rejected" '[ -f "$T/inbox/.rejected/$(date +%F)/bob/owner-private/codex/nope.jsonl" ]'
check "fresh file left settling" '[ -f "$T/inbox/bob/research-alpha/codex/fresh.jsonl" ]'
check "exit 0" '[ "$(cat "$T/rc")" = 0 ]'

echo "T7 grok: only chat_history.jsonl goes to gbrain; its summary.json sidecar moves with it"
setup
g="$T/inbox/alice/research-alpha/grok/%2FUsers%2Fme%2Fproj/0198-uuid"
stage "$g/chat_history.jsonl"; stage "$g/summary.json"
run
dg="$T/inbox/.done/$(date +%F)/alice/research-alpha/grok/%2FUsers%2Fme%2Fproj/0198-uuid"
check "summary.json not passed to gbrain" '! passed_to_gbrain summary.json'
check "chat + sidecar moved to .done" '[ -f "$dg/chat_history.jsonl" ] && [ -f "$dg/summary.json" ]'
check "no failure recorded" '[ "$(cat "$T/rc")" = 0 ] && [ -z "$(ls -A "$T/inbox/.attempts")" ]'

echo "T8 .done is capped by size: oldest processed copies go first"
setup
for i in 1 2 3; do mkdir -p "$T/inbox/.done/2026-01-0$i/owner/research-alpha/hermes"
  head -c 600000 /dev/urandom > "$T/inbox/.done/2026-01-0$i/owner/research-alpha/hermes/s$i.db"; sleep 1.1; done
env PATH="$T/bin:$PATH" FAKE_ARGS="$T/args" GBRAIN_BIN="$T/bin/gbrain" GBRAIN_INBOX="$T/inbox" \
    GBRAIN_INBOX_POLICY="$T/policy" GBRAIN_LOG_DIR="$T/logs" GBRAIN_DONE_MAX_MB=1 \
    GBRAIN_CONF="$T/none.conf" GBRAIN_CONF_OPTIONAL=1 GBRAIN_ROOT="$T/root" \
    bash "$SCRIPT" > "$T/run.out" 2>&1
check "oldest copy deleted" '[ ! -f "$T/inbox/.done/2026-01-01/owner/research-alpha/hermes/s1.db" ]'
check "newest copy kept" '[ -f "$T/inbox/.done/2026-01-03/owner/research-alpha/hermes/s3.db" ]'
check ".done under the cap" '[ "$(du -sk "$T/inbox/.done" | cut -f1)" -le 1100 ]'

echo "---"; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
