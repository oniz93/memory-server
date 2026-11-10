#!/usr/bin/env bash
# inbox-key.sh — give a collaborator write-only rsync access to their own inbox, nothing else.
#
#   inbox-key.sh add <person> <pubkey-file>    append a restricted key to GBRAIN_USER's authorized_keys
#   inbox-key.sh remove <person>               drop every inbox key of <person>
#   inbox-key.sh list
#
# The key can only run `rrsync -munge -no-del -wo <inbox>/<person>`: write-only, confined to that
# directory, uploaded symlinks are munged (never usable as links), no deletes, no shell, no
# port/agent/X11 forwarding, no pty (`restrict`). It is installed in GBRAIN_USER's authorized_keys
# so no extra login account or sshd change is needed; run this script as that user.
#
# Client side:  rsync -a <staged-dir>/ <ssh-alias>:<source-id>/     (see AGENT_SETUP.md, step 5)
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"
AK="${AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
INBOX="$GBRAIN_INBOX"
POLICY="$GBRAIN_INBOX_POLICY"
RRSYNC_OPTS="-munge -no-del -wo"
valid_person() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }
die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in
  add)
    person="${2:-}"; keyfile="${3:-}"
    valid_person "$person" || die "bad person name"
    grep -qE "^$person:" "$POLICY" || die "$person has no line in $POLICY; add it first"
    [ -r "$keyfile" ] || die "cannot read $keyfile"
    key="$(grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+' "$keyfile" | head -1 | awk '{print $1" "$2}')"
    [ -n "$key" ] || die "no public key found in $keyfile"
    ssh-keygen -l -f <(echo "$key") >/dev/null || die "invalid public key"
    grep -qF "$key" "$AK" 2>/dev/null && die "that key is already in $AK"
    install -d -m 0750 "$INBOX/$person"
    cp -p "$AK" "$AK.bak-inbox-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf 'restrict,command="/usr/bin/rrsync %s %s/%s" %s gbrain-inbox:%s\n' "$RRSYNC_OPTS" "$INBOX" "$person" "$key" "$person" >> "$AK"
    chmod 600 "$AK"
    echo "added write-only inbox key for $person ($(ssh-keygen -l -f <(echo "$key") | awk '{print $2}'))" ;;
  remove)
    person="${2:-}"; valid_person "$person" || die "usage: remove <person> (literal name)"
    tag=" gbrain-inbox:$person"
    tmp="$(mktemp "$AK.XXXXXX")"
    # Literal suffix match in awk; any filter failure aborts before $AK is touched.
    if ! awk -v tag="$tag" 'substr($0, length($0) - length(tag) + 1) != tag' "$AK" > "$tmp"; then
      rm -f "$tmp"; die "could not filter $AK; nothing changed"
    fi
    other_before=$(awk '!/ gbrain-inbox:/' "$AK" | wc -l) || { rm -f "$tmp"; die "count failed; nothing changed"; }
    other_after=$(awk '!/ gbrain-inbox:/' "$tmp" | wc -l)  || { rm -f "$tmp"; die "count failed; nothing changed"; }
    if [ "$other_before" != "$other_after" ]; then rm -f "$tmp"; die "would change non-inbox keys; nothing changed"; fi
    removed=$(( $(wc -l < "$AK") - $(wc -l < "$tmp") ))
    if [ "$removed" -le 0 ]; then rm -f "$tmp"; echo "no inbox keys for $person"; exit 0; fi
    cp -p "$AK" "$AK.bak-inbox-$(date +%Y%m%d%H%M%S)"
    chmod 600 "$tmp"; mv -f "$tmp" "$AK"
    echo "removed $removed key(s) for $person" ;;
  list)
    grep -o ' gbrain-inbox:[a-z0-9_-]*$' "$AK" 2>/dev/null | sort | uniq -c || echo "no inbox keys" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
