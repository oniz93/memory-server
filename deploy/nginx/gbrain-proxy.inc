# /etc/nginx/snippets/gbrain-proxy.inc — upstream settings (MCP streamable HTTP / SSE safe)
proxy_pass         http://127.0.0.1:@HTTP_PORT@;   # rendered by enable-frontdoor.sh
proxy_http_version 1.1;
proxy_set_header   Host              $host;
proxy_set_header   X-Real-IP         $remote_addr;
proxy_set_header   X-Forwarded-For   $remote_addr;   # overwrite: gbrain trusts exactly one hop
proxy_set_header   X-Forwarded-Proto $scheme;
proxy_set_header   Connection        "";
proxy_buffering    off;
proxy_cache        off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
