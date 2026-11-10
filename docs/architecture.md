# Architecture and security model

## Shape

```
                        front door (one or more, all behind the same gate)
   agents ── MCP ──►   nginx: public TLS / Tailscale address / WireGuard address
                               │  bearer token required on /mcp, fail2ban on failures
                               ▼
                        gbrain serve  127.0.0.1:3131        (systemd, sandboxed, memory-capped)
                               │  per-token source grants enforced in SQL
                               ▼
                        Postgres 17 + pgvector  127.0.0.1:5433   (container, memory-capped)

   laptops ── rsync over an upload-only SSH key ──►  $ROOT/inbox/<person>/<source>/<harness>/…
                                                            │ every 15 min (systemd timer, sandboxed)
                                                            ▼
                                             gbrain transcripts ingest  ──►  conversation pages
```

One brain (one database), many **sources**. A source is the unit of sharing: one per shared
project, plus private ones. Two lanes fill it:

| Lane | What | Trigger | Lands in |
|---|---|---|---|
| Live memory | facts and pages an agent saves (`remember`, `put_page`) | the agent, when asked or when it judges it useful | the token's write source |
| Transcripts | whole sessions (user and assistant text) | hourly sync from each machine, then the server's ingest timer | the source named by the upload path |

## What protects what

| Boundary | Mechanism |
|---|---|
| A person only reads their sources | GBrain token grants, enforced server-side for every read, search and write. A token reads its granted sources and writes only the first. |
| Private pages | A source that is not federated and not granted is invisible: searches return nothing and direct reads say `permission_denied` or `page_not_found`. |
| No prompt-injection path from shared to private | No credential both reads a private source and writes a shared one (see [server.md](server.md#3-sources-and-tokens)). |
| Unauthenticated traffic | The gate drops it at nginx; only the OAuth token and discovery endpoints answer without a bearer, rate-limited. fail2ban bans repeat offenders. |
| Uploads can't read, delete or run anything | The upload key is pinned to `rrsync -munge -no-del -wo` on the person's own inbox, with `restrict`. The inbox filesystem is `nodev,nosuid,noexec`. |
| Uploads can't reach other people's sources | A policy file says which sources each person may upload into; anything else is quarantined, never ingested. |
| Hostile upload contents | The ingester handles names NUL-safe, rejects control characters, never follows symlinks, and checks that every path resolves inside `<person>/<source>/` before reading or moving it. |
| A parser bug in the ingest path | The ingest and serve units are sandboxed: no privilege escalation, no docker/containerd socket, no `~/.ssh`, read-only home, writes only to their own directories. |
| Uploads can't fill the disk | The inbox is a fixed-size loop image; processed copies are capped by age and size. |
| Data disk not mounted | Units require the mount; Postgres never auto-creates its data directory; the installer refuses to create an empty database on an existing install. |
| Nothing leaves the server | No embeddings, no LLM calls, unless the LLM lane is switched on; then only through a loopback shim with a daily cap. |

**Not protected against:** anyone with a shell or database access on the server reads everything.
Collaborators get tokens and an upload-only key, never a login. The owner is trusted.

## Design choices and their trade-offs

| Choice | Why | Cost |
|---|---|---|
| One source per shared project | Unrelated work never mixes; a grant is the whole access decision | More sources and grants to manage |
| Keyword search, no embeddings | No text leaves the server; no model spend | Weaker recall on paraphrased questions |
| Automatic saving of what users say: off | In a shared brain an agent must not quietly store someone's remarks where others can read them | Agents only save when asked or when instructed by the project's agent rules |
| Server advertises the everyday tool set (33 tools) | Most MCP clients can only call advertised tools; with only the seven memory verbs agents could not search or read pages | Longer tool list in each harness |
| Agents "read memory first" through project instructions | Works in every harness; GBrain's per-turn context hooks need a local single-user brain | It is an instruction, not a guarantee |
| Transcripts uploaded by file, ingested by the server | Collaborators never hold database credentials; the server controls redaction and placement | Up to ~15 minutes until searchable; needs an upload key per machine |
| Upload keys on the service user's account | No extra login account or sshd change | The forced-command restriction is the boundary; use a separate account if you want two |
| VPN doors use plain HTTP on the VPN address | The tunnel already encrypts and authenticates; no certificate to manage | Only as trustworthy as the VPN |
| Optional LLM lane through a shim | The provider needs headers GBrain doesn't send; one place to cap and switch off | An extra small service when enabled |
| Templates rendered by an installer | One config file drives paths, ports, user and caps | Edit the config and re-run, not the installed files |

## What a transcript becomes

Kept: every user and assistant text turn, in order, with timestamps; long sessions are split into
parts that stay searchable. Dropped: system prompts, reasoning, tool calls and tool output.
Common secret patterns are redacted before anything is written, but that is not a guarantee:
people should skim what they upload. Imports are idempotent: re-sending an unchanged session
costs nothing, and a session that grew is updated.

## How it was verified

- **Isolation**: canary pages in a shared and a private source, queried over MCP with every
  token: default search, cross-source search, direct reads and writes.
- **Gate**: a throwaway nginx instance on loopback ports with the real server behind it: missing
  or short bearer dropped, wrong bearer 401, valid token served, `/admin` only on the VPN-style
  door, rate limits, secret-bearing paths redacted in the log. fail2ban: filter matches exactly
  the failure lines; a live ban and unban.
- **Uploads**: `tests/test_ingest_inbox.sh` (newline-in-filename injection, symlinked
  directories, partial batch failures, vanished files, policy comments, sidecar files, retention)
  and `tests/test_inbox_key.sh`; a real restricted key over SSH: writes confined, reads, `..`,
  absolute paths, shell, forwarding and deletes refused, symlinks munged.
- **Sandboxes and quota**: `tests/test_unit_sandbox.sh`, `tests/test_inbox_quota.sh`.
- **Transcript formats**: each harness's staged output through `gbrain transcripts ingest
  --dry-run`, then a real ingest and a search from another person's token.
- **Data move**: `move-data.sh` between two disks on a live install, with row counts compared.
- **Harness connections** (project-scoped config with the token only in the environment):
  Claude Code, Pi and Hermes connected live; OpenCode's project config was verified but its
  background service could not be tested live; Codex and Grok Build follow their documentation
  and include a verify step in the guide.

A fresh review of the first version found two critical holes in the upload ingester (filename
injection and symlink following). Both are fixed and covered by the tests above; the lesson is
in the "Hostile upload contents" row.
