#!/usr/bin/env bun
// llm-shim.ts — loopback OpenAI-compatible shim: gbrain (litellm recipe) -> OpenCode Go.
//
// Why a shim: OpenCode Go wants a stable `x-opencode-session` header and a non-generic
// User-Agent, which gbrain's OpenAI-compatible client does not send. The shim also keeps the Go
// key out of gbrain's config, enforces a daily request cap, and is the single off-switch for
// "transcript text leaves this server" (stop the unit and nothing is sent).
//
//   POST /v1/chat/completions   -> $GO_BASE/openai/v1/chat/completions   (streaming passthrough)
//   GET  /v1/models             -> $GO_BASE/v1/models
//   POST /v1/embeddings         -> 501 (OpenCode Go has no embeddings; search stays keyword)
//
// Env: OPENCODE_GO_API_KEY (required)  SHIM_LOCAL_KEY (required; gbrain sends it as LITELLM_API_KEY)
//      SHIM_PORT [4010]  GO_BASE [https://opencode.ai/inference/go]  DAILY_REQUEST_CAP [500]
//      USAGE_FILE [$TMPDIR/gbrain-llm-usage.json; the systemd unit points it at the log dir]
// Logs one line per request (time, path, model, status, ms, bytes) — never prompt or completion text.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { hostname } from 'node:os';

const KEY = process.env.OPENCODE_GO_API_KEY ?? '';
const LOCAL = process.env.SHIM_LOCAL_KEY ?? '';
const PORT = Number(process.env.SHIM_PORT ?? 4010);
const GO_BASE = (process.env.GO_BASE ?? 'https://opencode.ai/inference/go').replace(/\/+$/, '');
const CAP = Number(process.env.DAILY_REQUEST_CAP ?? 500);
const USAGE_FILE = process.env.USAGE_FILE ?? `${process.env.TMPDIR ?? '/tmp'}/gbrain-llm-usage.json`;
const UA = 'gbrain-memory/1.0 (+self-hosted shared research brain)';

if (!KEY || !LOCAL) {
  console.error('llm-shim: OPENCODE_GO_API_KEY and SHIM_LOCAL_KEY are required');
  process.exit(2);
}

type Usage = { day: string; requests: number };
const today = () => new Date().toISOString().slice(0, 10);
let usage: Usage = { day: today(), requests: 0 };
try {
  if (existsSync(USAGE_FILE)) usage = JSON.parse(readFileSync(USAGE_FILE, 'utf8'));
} catch { /* start fresh */ }
const bump = () => {
  if (usage.day !== today()) usage = { day: today(), requests: 0 };
  usage.requests++;
  try { writeFileSync(USAGE_FILE, JSON.stringify(usage)); } catch { /* best effort */ }
};

// One stable session id per host per UTC day: Go routes/caches by it.
const sessionId = () => `gbrain-${hostname()}-${today()}`;

const json = (status: number, message: string) =>
  new Response(JSON.stringify({ error: { type: 'llm_shim', message } }), {
    status, headers: { 'content-type': 'application/json' },
  });

const log = (line: Record<string, unknown>) => {
  const s = JSON.stringify({ ts: new Date().toISOString(), ...line });
  console.log(s);
};

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

Bun.serve({
  hostname: '127.0.0.1',
  port: PORT,
  idleTimeout: 255,
  async fetch(req) {
    const url = new URL(req.url);
    const t0 = performance.now();
    const auth = req.headers.get('authorization') ?? '';
    if (!timingSafeEqual(auth, `Bearer ${LOCAL}`)) return json(401, 'missing or wrong local shim key');

    if (url.pathname === '/health') return json(200, `ok; ${usage.day} requests=${usage.requests}/${CAP}`);
    if (url.pathname === '/v1/embeddings') {
      return json(501, 'OpenCode Go has no embeddings endpoint; gbrain stays on keyword search');
    }

    let upstream: string;
    if (req.method === 'POST' && url.pathname === '/v1/chat/completions') upstream = `${GO_BASE}/openai/v1/chat/completions`;
    else if (req.method === 'GET' && url.pathname === '/v1/models') upstream = `${GO_BASE}/v1/models`;
    else return json(404, `not proxied: ${req.method} ${url.pathname}`);

    if (usage.day !== today()) usage = { day: today(), requests: 0 };
    if (usage.requests >= CAP) {
      log({ path: url.pathname, status: 429, note: 'daily cap' });
      return json(429, `daily request cap ${CAP} reached; resets at 00:00 UTC`);
    }

    let body: string | undefined;
    let model: string | undefined;
    if (req.method === 'POST') {
      body = await req.text();
      try { model = JSON.parse(body).model; } catch { return json(400, 'body is not JSON'); }
    }
    bump();
    const res = await fetch(upstream, {
      method: req.method,
      body,
      headers: {
        'authorization': `Bearer ${KEY}`,
        'content-type': 'application/json',
        'accept': req.headers.get('accept') ?? 'application/json',
        'user-agent': UA,
        'x-opencode-session': sessionId(),
      },
    }).catch((e: unknown) => e as Error);
    if (res instanceof Error) {
      log({ path: url.pathname, model, status: 502, ms: Math.round(performance.now() - t0), error: res.message });
      return json(502, `upstream unreachable: ${res.message}`);
    }
    log({ path: url.pathname, model, status: res.status, ms: Math.round(performance.now() - t0),
          bytes: Number(res.headers.get('content-length') ?? -1) });
    const headers = new Headers();
    for (const h of ['content-type', 'cache-control']) {
      const v = res.headers.get(h);
      if (v) headers.set(h, v);
    }
    return new Response(res.body, { status: res.status, headers });
  },
});

console.log(`llm-shim listening on 127.0.0.1:${PORT} -> ${GO_BASE} (cap ${CAP}/day)`);
