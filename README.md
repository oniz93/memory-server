# Shared agent memory with GBrain

A small, self-hosted setup that gives a group of people **one shared memory for their coding
agents**, built on [GBrain](https://github.com/garrytan/gbrain):

- every harness (Claude Code, Codex, OpenCode, Pi, Grok Build, Hermes) connects to the same
  memory over MCP with a personal token;
- each token only sees the **sources** it was granted, so a project can be shared with some
  people while private notes stay private;
- past and ongoing **session transcripts** are uploaded per project and become searchable, cited
  memory for everyone on that project;
- one file, [AGENT_SETUP.md](AGENT_SETUP.md), is handed to an agent, which then connects a
  project, tells its agents to read the memory first, offers the transcript backfill, and sets
  up an hourly sync.

Nothing here is a hosted service: you run it on your own server, and no text leaves that server
unless you turn on the optional LLM lane.

```
 agents (any harness)                       your server
 ────────────────────                       ───────────────────────────────────────────────
  MCP + bearer token   ──► front door ──►   gbrain serve (127.0.0.1)  ──►  Postgres + pgvector
                           nginx/TLS,                                      sources: research-alpha,
                           Tailscale or                                             owner-private, …
                           WireGuard
  transcripts (rsync, ──►  upload inbox  ──► ingest timer (every 15 min) ──►  conversation pages
  upload-only SSH key)     capped, per person, per source
```

## Who reads what

| You are | Read |
|---|---|
| A collaborator joining an existing brain | Give your agent the `AGENT_SETUP-<you>.md` the owner sent you. That is all. |
| The owner setting up the server | [docs/server.md](docs/server.md) |
| Curious how it works and what it protects against | [docs/architecture.md](docs/architecture.md) |
| Working on transcript upload / Hermes cron jobs | [docs/ingestion.md](docs/ingestion.md) |

## Server quick start

Needs a Linux server with systemd, Docker (with the compose plugin), `rsync`, `python3` and the
Postgres client tools (`pg_isready`). About 400 MB of RAM in use; memory is capped.

```bash
git clone <this repo> && cd <repo>
sudo deploy/install.sh              # first run creates /etc/gbrain/gbrain.conf and stops
sudoedit /etc/gbrain/gbrain.conf    # set GBRAIN_USER, GBRAIN_BUN_BIN and GBRAIN_DATA_DIR
sudo deploy/install.sh              # installs Postgres, gbrain, units, timers; safe to re-run
```

`GBRAIN_DATA_DIR` is where everything that grows goes (database, backups, logs, upload inbox).
Point it at your larger disk. To change it later, use `bin/move-data.sh <new-dir>`, which copies,
switches, verifies row counts and keeps the old copy until you delete it.

Then create sources and tokens, enable a front door, and hand out the agent guide:
[docs/server.md](docs/server.md) walks through each step.

## Repository layout

| Path | What |
|---|---|
| `AGENT_SETUP.md` | The guide an agent follows on a person's machine (helper script embedded) |
| `scripts/gbrain_project.py` | Client helper: connection check, transcript scan / stage / upload, Hermes cron-job and thread selection, hourly sync (stdlib-only Python) |
| `scripts/build_agent_setup.py` | Re-embeds the helper into the guide and writes a personalised copy per person |
| `deploy/install.sh` | Server installer / updater, driven by `/etc/gbrain/gbrain.conf` |
| `deploy/gbrain.conf.example` | Every server setting, with the data directory |
| `deploy/bin/` | Server tools: inbox ingester, front doors, upload keys, backups, health check, data move, LLM lane |
| `deploy/systemd/`, `deploy/compose.yml.in`, `deploy/nginx/`, `deploy/fail2ban/` | Templates the installer renders |
| `deploy/contrib/` | Optional hook for an existing bash monitoring script |
| `tests/` | Behavioural tests for the ingester, upload keys, unit sandboxes, inbox quota, template rendering, and a check that nothing private is published |
| `docs/` | Server guide, architecture and security model, ingestion |

## Tests

```bash
bash tests/test_render.sh          # anywhere: templates render and validate
bash tests/test_public_safe.sh     # anywhere: nothing site-specific or secret is tracked
bash tests/test_ingest_inbox.sh    # GNU/Linux: hostile-upload handling of the ingester
bash tests/test_inbox_key.sh       # GNU/Linux: upload-key management
sudo bash tests/test_unit_sandbox.sh /etc/systemd/system/gbrain-ingest.service <writable dirs…>   # installed server
sudo bash tests/test_inbox_quota.sh                                                               # installed server
```

## Limits worth knowing

- **Search is keyword-only by default.** No embeddings are computed, so nothing leaves the
  server; recall on paraphrased questions is weaker. The optional LLM lane (OpenCode Go) enables
  synthesis and query expansion, not embeddings.
- **Agents read the memory when instructed to.** The guide adds a "read memory first" block to
  each project's agent instructions; there is no hook that injects memory into every turn.
- **Pi and OpenCode transcripts** have no GBrain importer. The helper can convert them to a
  format GBrain imports; they are labelled with their real origin.
- **Anyone with shell or database access on the server can read everything.** Collaborators get
  MCP tokens and an upload-only key, never a login.
- GBrain itself moves fast. `GBRAIN_REF` in the config pins the version you install.

## Before you publish your own copy

`private/` and `out/` are git-ignored: keep your real config, notes and personalised guides
there. `tests/test_public_safe.sh` fails if a tracked file contains an IP address, key
fingerprint, e-mail address, home directory, token-like string, or anything matching your own
`private/deny-patterns.txt`.
