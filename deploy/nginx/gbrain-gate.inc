# /etc/nginx/snippets/gbrain-gate.inc — strict auth gate shared by every GBrain front door.
# The including server block must `set $gbrain_admin_ok 0|1;` (1 only on VPN-bound front doors).
#
#   /mcp                          bearer header required, else connection dropped (444)
#   /token /revoke                POST only, 6 req/min/IP (OAuth client-credentials exchange)
#   /.well-known/oauth-*          GET only, 6 req/min/IP (OAuth discovery for thin clients)
#   /admin                        tunnel front doors only (still needs the owner login)
#   everything else (/health, /metrics, /register, /authorize, scanners)   dropped (444)
#
# 401/403/444 responses are counted by fail2ban jail gbrain-auth (5 in 10 min -> ban);
# 429 (rate limit) is not, so a legitimate burst never bans a collaborator.

access_log /var/log/nginx/gbrain-access.log gbrain;
error_log  /var/log/nginx/gbrain-error.log warn;
client_max_body_size 64m;
limit_conn gbrain_conn 20;
limit_req_status  429;
limit_conn_status 429;
server_tokens off;

location = /mcp {
    if ($gbrain_bearer = 0) { return 444; }
    limit_req zone=gbrain_mcp burst=60 nodelay;
    include /etc/nginx/snippets/gbrain-proxy.inc;
}

location ~ ^/(token|revoke)$ {
    limit_except POST { deny all; }
    limit_req zone=gbrain_auth burst=5 nodelay;
    include /etc/nginx/snippets/gbrain-proxy.inc;
}

location ~ ^/\.well-known/(oauth-authorization-server|oauth-protected-resource)(/.*)?$ {
    limit_except GET { deny all; }
    limit_req zone=gbrain_auth burst=10 nodelay;
    include /etc/nginx/snippets/gbrain-proxy.inc;
}

location ^~ /admin {
    if ($gbrain_admin_ok = 0) { return 444; }
    limit_req zone=gbrain_mcp burst=60 nodelay;
    include /etc/nginx/snippets/gbrain-proxy.inc;
}

location / { return 444; }
