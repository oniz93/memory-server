#!/usr/bin/env bash
# enable-frontdoor.sh — turn GBrain front doors on/off. Every door shares one strict gate
# (snippets/gbrain-gate.inc) and the fail2ban jail gbrain-auth. Nothing is enabled by default:
# gbrain itself only listens on 127.0.0.1.
#
#   sudo enable-frontdoor.sh public <host>      HTTPS on 443 via nginx + certbot (needs DNS A -> this box)
#   sudo enable-frontdoor.sh tailscale          HTTP on this node's Tailscale IPv4 only
#   sudo enable-frontdoor.sh wireguard <ip>     HTTP on a WireGuard interface address only
#   sudo enable-frontdoor.sh disable public|tailscale|wireguard
#   sudo enable-frontdoor.sh status
#
# VPN doors listen on GBRAIN_TUNNEL_PORT (/etc/gbrain/gbrain.conf). GBRAIN_PUBLIC_URL (the OAuth
# issuer, in secrets/serve.env) follows the canonical door: public wins; otherwise the first VPN
# door enabled while it is still the loopback default.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/gbrain-env.sh"

SRC="$GBRAIN_ROOT/nginx"
SERVE_ENV="$GBRAIN_SECRETS/serve.env"
SITES_AVAIL=/etc/nginx/sites-available
SITES_EN=/etc/nginx/sites-enabled
COMMON=(/etc/nginx/conf.d/gbrain-http.conf /etc/nginx/snippets/gbrain-gate.inc /etc/nginx/snippets/gbrain-proxy.inc)
NONLOCAL=/etc/sysctl.d/60-gbrain-nonlocal-bind.conf

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"

any_site_enabled() { compgen -G "$SITES_EN/gbrain-*" >/dev/null; }
any_tunnel_enabled() { [ -e "$SITES_EN/gbrain-tailscale" ] || [ -e "$SITES_EN/gbrain-wireguard" ]; }

install_common() {
  install -m0644 "$SRC/gbrain-http.conf" /etc/nginx/conf.d/gbrain-http.conf
  install -d /etc/nginx/snippets
  sed "s/@HTTP_PORT@/$GBRAIN_HTTP_PORT/g" "$SRC/gbrain-proxy.inc" > /etc/nginx/snippets/gbrain-proxy.inc
  install -m0644 "$SRC/gbrain-gate.inc" /etc/nginx/snippets/gbrain-gate.inc
  for f in gbrain-access.log gbrain-error.log; do
    [ -f "/var/log/nginx/$f" ] || install -m0640 -o root -g adm /dev/null "/var/log/nginx/$f"
  done
}

# Shared files only exist while at least one door is enabled, so a leftover can never break the
# other sites' nginx reloads.
remove_common_if_unused() { any_site_enabled || rm -f "${COMMON[@]}"; }

# activate <name> <rendered-file>: enable the site, validate, reload; roll back on a bad config.
activate() {
  local name="$1" rendered="$2" log
  log="$(mktemp)"
  install -m0644 "$rendered" "$SITES_AVAIL/gbrain-$name"
  ln -sfn "$SITES_AVAIL/gbrain-$name" "$SITES_EN/gbrain-$name"
  if ! nginx -t 2>"$log"; then
    rm -f "$SITES_EN/gbrain-$name"; remove_common_if_unused
    cat "$log" >&2; rm -f "$log"
    die "nginx -t failed; gbrain-$name rolled back, the running nginx was not touched"
  fi
  rm -f "$log"
  systemctl reload nginx
  echo "enabled gbrain-$name"
}

set_public_url() { # <url> [force]
  local cur; cur="$(sed -n 's/^GBRAIN_PUBLIC_URL=//p' "$SERVE_ENV")"
  if [ "${2:-}" = force ] || [ -z "$cur" ] || [[ "$cur" == http://127.0.0.1:* ]]; then
    if grep -q '^GBRAIN_PUBLIC_URL=' "$SERVE_ENV"; then
      sed -i "s#^GBRAIN_PUBLIC_URL=.*#GBRAIN_PUBLIC_URL=$1#" "$SERVE_ENV"
    else
      echo "GBRAIN_PUBLIC_URL=$1" >> "$SERVE_ENV"
    fi
    systemctl restart gbrain.service
    echo "GBRAIN_PUBLIC_URL=$1 (gbrain restarted)"
  else
    echo "GBRAIN_PUBLIC_URL stays $cur"
  fi
}

local_ipv4s() { ip -4 -o addr show | awk '{sub(/\/.*/, "", $4); print $4}'; }

tunnel() { # <name> <ip>
  local name="$1" ip="$2" port="$GBRAIN_TUNNEL_PORT" tmp
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad IPv4: $ip"
  case "$ip" in 127.*|0.0.0.0) die "$ip is not a VPN address" ;; esac
  local_ipv4s | grep -qx "$ip" || die "$ip is not assigned to any interface on this host (is the VPN up?)"
  # Refuse an address on the default-route interface: that would be a public listener.
  if [ "$(ip -4 -o addr show | awk -v a="$ip" '{sub(/\/.*/, "", $4)} $4 == a {print $2}')" = "$(ip -4 route show default | awk '{print $5; exit}')" ]; then
    die "$ip is on the default-route interface, not a VPN interface"
  fi
  # Let nginx bind the VPN address even if the interface comes up late at boot, instead of
  # failing to start and taking every other site on this box down with it.
  echo 'net.ipv4.ip_nonlocal_bind = 1' > "$NONLOCAL"; sysctl -q -p "$NONLOCAL"
  install_common
  tmp="$(mktemp)"
  sed -e "s/__NAME__/$name/g" -e "s/__LISTEN_ADDR__/$ip/" -e "s/__PORT__/$port/" \
      "$SRC/gbrain-tunnel.conf.template" > "$tmp"
  activate "$name" "$tmp"; rm -f "$tmp"
  set_public_url "http://$ip:$port"
  echo "MCP endpoint: http://$ip:$port/mcp   (bearer token required; /admin reachable here)"
}

public() { # <host>
  local host="$1" tmp
  [[ "$host" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "bad host: $host"
  local want="${GBRAIN_PUBLIC_IP:-}" resolved
  resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [ -n "$resolved" ] || die "$host does not resolve; add the DNS A record first"
  if [ -n "$want" ]; then
    grep -qx "$want" <<<"$resolved" || die "$host resolves to $(tr '\n' ' ' <<<"$resolved"), not GBRAIN_PUBLIC_IP=$want"
  else
    grep -qxFf <(local_ipv4s) <<<"$resolved" \
      || die "$host resolves to $(tr '\n' ' ' <<<"$resolved"), which is not an address of this host (behind NAT? set GBRAIN_PUBLIC_IP in $GBRAIN_CONF)"
  fi
  if [ ! -s "/etc/letsencrypt/live/$host/fullchain.pem" ]; then
    # Nothing of ours is installed in nginx yet, so a certbot failure leaves nginx untouched.
    certbot certonly --nginx -d "$host" --non-interactive --keep-until-expiring \
      || die "certbot failed for $host; nothing was changed"
  fi
  install_common
  tmp="$(mktemp)"
  sed -e "s/__BRAIN_HOST__/$host/g" "$SRC/gbrain-public.conf.template" > "$tmp"
  activate public "$tmp"; rm -f "$tmp"
  set_public_url "https://$host" force
  echo "MCP endpoint: https://$host/mcp   (bearer token required; /admin NOT exposed here)"
}

disable() { # <name>
  [ -e "$SITES_EN/gbrain-$1" ] || die "gbrain-$1 is not enabled"
  rm -f "$SITES_EN/gbrain-$1"
  remove_common_if_unused
  if ! any_tunnel_enabled && [ -f "$NONLOCAL" ]; then
    rm -f "$NONLOCAL"; sysctl -q -w net.ipv4.ip_nonlocal_bind=0 || true
  fi
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    echo "disabled gbrain-$1 (GBRAIN_PUBLIC_URL unchanged; edit $SERVE_ENV if it pointed here)"
  else
    die "gbrain-$1 was removed from sites-enabled, but nginx -t fails for another reason, so nginx was NOT reloaded and the door is STILL LIVE. Fix nginx, then: systemctl reload nginx"
  fi
}

status() {
  echo "enabled front doors:"
  if any_site_enabled; then ls -1 "$SITES_EN" | grep '^gbrain-' | sed 's/^/  /'; else echo "  (none: loopback only)"; fi
  echo "issuer: $(sed -n 's/^GBRAIN_PUBLIC_URL=//p' "$SERVE_ENV")"
  fail2ban-client status gbrain-auth 2>/dev/null | sed -n 's/^.*\(Currently banned\|Total banned\|Banned IP list\)/  \1/p' || true
}

case "${1:-}" in
  public)    [ -n "${2:-}" ] || die "usage: public <host>"; public "$2" ;;
  tailscale) ip="$(tailscale ip -4 2>/dev/null | head -1)"; [ -n "$ip" ] || die "tailscale has no IPv4"
             tunnel tailscale "$ip" ;;
  wireguard) [ -n "${2:-}" ] || die "usage: wireguard <interface-ip>"; tunnel wireguard "$2" ;;
  disable)   case "${2:-}" in public|tailscale|wireguard) disable "$2" ;; *) die "usage: disable public|tailscale|wireguard" ;; esac ;;
  status)    status ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
