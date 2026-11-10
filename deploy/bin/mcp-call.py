#!/usr/bin/env python3
"""mcp-call.py — minimal streamable-HTTP MCP client for smoke/access tests (stdlib only).

  mcp-call.py --url http://127.0.0.1:3131/mcp --token-file T init
  mcp-call.py --url ... --token-file T tools
  mcp-call.py --url ... --token-file T call <tool> '<json-args>'

Token can also come from $GBRAIN_TOKEN. Prints the JSON-RPC result (or error) as JSON.
Exit 0 on a JSON-RPC result, 3 on a JSON-RPC/tool error, 4 on HTTP error.
"""
import argparse, json, os, sys, urllib.request, urllib.error

def parse_body(raw, ctype):
    text = raw.decode("utf-8", "replace")
    if "text/event-stream" in (ctype or ""):
        msgs = [json.loads(l[5:].strip()) for l in text.splitlines()
                if l.startswith("data:") and l[5:].strip()]
        return msgs[-1] if msgs else {}
    return json.loads(text) if text.strip() else {}

class Client:
    def __init__(self, url, token):
        self.url, self.token, self.session, self.n = url, token, None, 0

    def rpc(self, method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None: body["params"] = params
        if not notify:
            self.n += 1; body["id"] = self.n
        h = {"content-type": "application/json",
             "accept": "application/json, text/event-stream",
             "user-agent": "gbrain-smoke/1.0"}
        if self.token: h["authorization"] = f"Bearer {self.token}"
        if self.session: h["mcp-session-id"] = self.session
        req = urllib.request.Request(self.url, json.dumps(body).encode(), h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                self.session = r.headers.get("mcp-session-id") or self.session
                return r.status, parse_body(r.read(), r.headers.get("content-type"))
        except urllib.error.HTTPError as e:
            raw = e.read()
            try: payload = parse_body(raw, e.headers.get("content-type"))
            except Exception: payload = {"raw": raw.decode("utf-8", "replace")[:500]}
            return e.code, payload

    def init(self):
        st, res = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "gbrain-smoke", "version": "1.0"}})
        if st == 200 and "result" in res:
            self.rpc("notifications/initialized", notify=True)
        return st, res

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os.environ.get("GBRAIN_MCP_URL", "http://127.0.0.1:3131/mcp"))
    ap.add_argument("--token-file")
    ap.add_argument("--max-chars", type=int, default=0, help="truncate printed output (0 = no limit)")
    ap.add_argument("cmd", choices=["init", "tools", "call"])
    ap.add_argument("rest", nargs="*")
    a = ap.parse_args()
    token = open(a.token_file).read().strip() if a.token_file else os.environ.get("GBRAIN_TOKEN", "")
    c = Client(a.url, token)
    st, res = c.init()
    if a.cmd != "init" and st == 200 and "result" in res:
        if a.cmd == "tools":
            st, res = c.rpc("tools/list", {})
            if "result" in res:
                res = {"result": {"tools": [t["name"] for t in res["result"].get("tools", [])]}}
        else:
            args = json.loads(a.rest[1]) if len(a.rest) > 1 else {}
            st, res = c.rpc("tools/call", {"name": a.rest[0], "arguments": args})
    out = json.dumps({"http": st, **(res if isinstance(res, dict) else {"body": res})}, indent=1)
    print(out[:a.max_chars] if a.max_chars else out)
    if st >= 400: sys.exit(4)
    if "error" in res or res.get("result", {}).get("isError"): sys.exit(3)

if __name__ == "__main__":
    main()
