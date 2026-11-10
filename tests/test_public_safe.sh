#!/usr/bin/env bash
# test_public_safe.sh — nothing site-specific or secret in the files that would be published.
# Checks every file git would track (or, outside a git repo, every file not under private/ or out/):
#   - IPv4 addresses other than loopback, the documentation ranges and obvious placeholders
#   - SSH key fingerprints and key material, e-mail addresses, home directories of real users
#   - long hex / base64 strings that look like tokens
#   - extra site-specific patterns, one regex per line, from private/deny-patterns.txt (not published)
#   bash tests/test_public_safe.sh          (works with the bash 3.2 that ships with macOS)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
LIST="$(mktemp)"; trap 'rm -f "$LIST" "$LIST.out"' EXIT
if git rev-parse --git-dir >/dev/null 2>&1; then
  git ls-files -co --exclude-standard > "$LIST"
else
  find . -type f -not -path './private/*' -not -path './out/*' -not -name '.DS_Store' -not -path '*/__pycache__/*' | sed 's#^\./##' > "$LIST"
fi
n="$(wc -l < "$LIST" | tr -d ' ')"
if [ "$n" -lt 10 ]; then echo "  FAIL only $n files found to scan: the check would be meaningless"; exit 1; fi

fail=0
scan() { # <label> <regex> [<allow-regex>]
  tr '\n' '\0' < "$LIST" | xargs -0 grep -nIE -- "$2" 2>/dev/null | grep -v '^tests/test_public_safe.sh:' > "$LIST.out" || true
  if [ -n "${3:-}" ]; then grep -vE -- "$3" "$LIST.out" > "$LIST.out2" || true; mv "$LIST.out2" "$LIST.out"; fi
  if [ -s "$LIST.out" ]; then
    echo "  FAIL $1"; head -8 "$LIST.out" | cut -c1-180 | sed 's/^/       /'; fail=$((fail+1))
  else
    echo "  PASS $1"
  fi
}
ip='(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)'
ok_ip='127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.66\.0\.1|100\.64\.0\.0|0\.60\.[0-9]+\.[0-9]+'
scan "no real IPv4 addresses"             "$ip" "$ok_ip"
scan "no SSH fingerprints / key material" 'SHA256:[A-Za-z0-9+/]{30,}|ssh-(ed25519|rsa) AAAA|BEGIN [A-Z ]*PRIVATE KEY'
scan "no e-mail addresses"                '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|net|org|dev|io|it|me)([^a-z]|$)' 'noreply@|@openssh\.com|@brain\.example\.org|@example\.(com|org)'
scan "no real home directories"           '/(Users|home)/[a-z][a-z0-9_-]+' '/home/(gbrain|alice|bob|me|you|user)([/ ."]|$)|/Users/(me|you|alice)([/ ."]|$)'
scan "no token-like secrets"              '(^|[^0-9a-f])[0-9a-f]{40,}([^0-9a-f]|$)|(^|[^A-Za-z0-9_-])[A-Za-z0-9_-]{64,}([^A-Za-z0-9_-]|$)' '[-_=]{20,}'
if [ -r private/deny-patterns.txt ]; then
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    scan "site deny-list: $pat" "$pat"
  done < private/deny-patterns.txt
else
  echo "  (no private/deny-patterns.txt: add one regex per line for your site, host and project names)"
fi
if grep -E '^(private|out)/|\.(env|token|pem|key)$' "$LIST" > "$LIST.out"; then
  echo "  FAIL sensitive file(s) would be published"; sed 's/^/       /' "$LIST.out"; fail=$((fail+1))
else
  echo "  PASS no private/, out/, *.env, *.token, *.pem or *.key file tracked"
fi
echo "---"
if [ "$fail" = 0 ]; then echo "public-safe: ok ($n files)"; else echo "public-safe: $fail problem group(s) in $n files"; fi
[ "$fail" = 0 ]
