# Connect this project to the shared brain (gbrain)

**You are a coding agent.** A human handed you this file to do four things:
1. Connect **this one project** to the research group's shared memory server (gbrain, over MCP).
2. Make this project's agents **read that memory before every new task or new scenario**.
3. **Propose** sending this project's previous session transcripts to it.
4. Keep the transcripts **in sync every hour**. Follow the steps in order. Wherever it says **ask**,
stop and get an explicit answer from the human first.

## 0. Values for this person

```
PERSON          = {{PERSON}}
GBRAIN_MCP_URL  = {{GBRAIN_MCP_URL}}
GBRAIN_SOURCE   = {{GBRAIN_SOURCE}}
GBRAIN_UPLOAD   = gbrain-upload:{{GBRAIN_SOURCE}}
GBRAIN_SSH      = {{GBRAIN_SSH_USER}}@{{GBRAIN_SSH_HOST}}
GBRAIN_HOSTKEY  = {{GBRAIN_HOSTKEY}}
TOKEN FILE      = ~/.config/gbrain/token     (0600; contains the bearer token, nothing else)
```

If a value still shows `{{...}}`, ask the human for it: the brain owner (whoever runs the server)
gave it to them. The token is never in this file; it is handed over separately.
- `GBRAIN_MCP_URL` usually looks like `http://100.x.y.z:3132/mcp` (Tailscale), `http://10.x.y.z:3132/mcp`
  (WireGuard) or `https://<host>/mcp`.
- `GBRAIN_UPLOAD` uses `gbrain-upload`, an SSH alias for a dedicated upload-only key that you set
  up in step 5.1. Until that key is registered on the server, a one-off upload can use the
  person's normal key, if the owner registered that one: `<GBRAIN_SSH>:<source>`.
- `GBRAIN_SSH` is the SSH user and host of the server's upload inbox. `GBRAIN_HOSTKEY` is the
  server's ED25519 host-key fingerprint (`SHA256:…`), used in step 5.1 to make sure uploads go to
  the right machine.

## Ground rules (read before doing anything)

1. **Scope is this project only.** The project is the current working directory (resolve symlinks
   with `pwd -P`). Never configure other projects, and never scan or upload sessions from other
   directories. Some harnesses have no per-project scope (Hermes, sometimes Codex). Before writing
   their user-level config, **ask**.
2. **The token is a secret.** Never print it, echo it, log it, paste it into chat, put it in a
   command line, or write it into any file inside the project. Config files reference
   `${GBRAIN_TOKEN}` / `{env:GBRAIN_TOKEN}` instead. The only files that may contain it are
   `~/.config/gbrain/token` and, for Hermes, the profile's `.env` (Hermes reads secrets only from there).
3. **Uploading publishes.** Everything sent to `GBRAIN_SOURCE` can be read by everyone granted that
   source (the whole research group), and you cannot delete it afterwards: only the brain owner can. Never
   upload without showing the exact list and getting an explicit "yes".
4. **Ask before** you edit a file that is committed to git, edit a shell profile, restart a
   background service, or write user-level (global) harness config.
5. Prefer each harness's own CLI over hand-editing its config. Back up any config file before
   editing it (`cp file file.bak-gbrain`).

## 1. Preflight

1. Project dir: `PROJECT="$(pwd -P)"`. Tell the human which directory you are about to connect.
2. Harnesses on this machine: `command -v claude codex opencode pi grok hermes`. Note which one
   *you* are running in. **Ask** which to configure for this project. The default is the one you
   are running in, plus any others the human names.
3. Token:
   - If `~/.config/gbrain/token` is missing, ask the human to create it themselves (so the token
     never passes through you): `mkdir -p ~/.config/gbrain && umask 077 && pbpaste > ~/.config/gbrain/token`
     on macOS, or their editor on Linux. Then `chmod 600 ~/.config/gbrain/token`.
   - For this session: `export GBRAIN_TOKEN="$(cat ~/.config/gbrain/token)"`.
   - Harnesses read the token from the environment **when they start**. **Ask** to add this line to
     the human's shell profile (`~/.zshrc` or `~/.bashrc`):
     `export GBRAIN_TOKEN="$(cat ~/.config/gbrain/token 2>/dev/null)"`.
     Apps launched from a GUI or IDE may not read the profile. Mention that.
4. Write the helper from the [appendix](#appendix-gbrain_projectpy) to a temp file (not into the
   project): `H="${TMPDIR:-/tmp}/gbrain_project.py"`. Needs `python3` (stdlib only) and `rsync`.
5. Connection check:
   `python3 "$H" check --url "$GBRAIN_MCP_URL"`. It must print `OK: gbrain …`, the token name and
   `search works: yes`.
   - If it fails, stop and report the message:
     - `cannot reach`: the front door, VPN or tunnel is down.
     - `HTTP 401`: wrong token.
     - A dropped connection with no HTTP status: the server's gate rejected the request.
   - **Do not retry in a loop.** Five rejected requests in ten minutes ban this machine's address
     for an hour or more. If it worked before and now every request is dropped, the address is
     probably banned: stop, and ask the brain owner to lift the ban.

## 2. Configure MCP for this project

The server name is always `gbrain`. Configure only the harnesses agreed in step 1.2. After each
one, run its verify command and record the result. The tool list you should see includes
`remember`, `recall`, `entity`, `synthesize`, `forget`, `context_pack`, `delta` and `request_tools`.

### Claude Code

```bash
claude mcp add -s local -t http gbrain "$GBRAIN_MCP_URL" -H 'Authorization: Bearer ${GBRAIN_TOKEN}'
claude mcp get gbrain          # expect: Status: ✔ Connected
```

- **Single quotes matter.** The literal `${GBRAIN_TOKEN}` is stored and expanded when Claude Code
  starts, so the token never lands in a file.
- `-s local` means private to this user, this project only, not committed.
- If the team wants the entry committed, use `-s project` instead. That writes `.mcp.json` with the
  same `${GBRAIN_TOKEN}` reference, and Grok Build also reads it. Each person then approves it
  once on first start.

### Codex

Codex reads project config from `.codex/config.toml`, but only in projects it trusts. Add:

```toml
[mcp_servers.gbrain]
url = "<GBRAIN_MCP_URL>"
bearer_token_env_var = "GBRAIN_TOKEN"
startup_timeout_sec = 30
```

- Verify from the project dir: `codex mcp list` must show `gbrain`.
- If it doesn't, this Codex version may ignore `mcp_servers` in project config. **Ask** before
  adding the same block to `~/.codex/config.toml`, which applies to every project. Say so in the
  report.

### OpenCode

OpenCode 2.x connects to MCP servers from its **background service**, which only has the
environment it was started with. A service started before `GBRAIN_TOKEN` was exported sends an
empty bearer, the gate drops it, and OpenCode's retries get this machine **banned** within
seconds. So check the service first:

```bash
opencode service status        # prints an address if the service is running
```

If it is running and was started before the token was exported (assume so on a first setup),
**ask** to restart it, because that interrupts running OpenCode sessions. Then, from this shell
(where `GBRAIN_TOKEN` is exported): `opencode service restart`. Only then add the server:

```bash
opencode mcp add gbrain --url "$GBRAIN_MCP_URL" --header 'Authorization=Bearer {env:GBRAIN_TOKEN}'
opencode mcp list              # expect: ✓ gbrain connected
```

- OpenCode 2.x writes the project's `opencode.json` by default (`--global` would write the user
  config). Older versions always write the global file. With those, add the entry to the project's
  `opencode.json` by hand:
  `{"mcp": {"gbrain": {"type": "remote", "url": "…", "headers": {"Authorization": "Bearer {env:GBRAIN_TOKEN}"}}}}`.
- If `gbrain` still shows `failed` (`ECONNRESET`, 401) while `check` passed, the service lacks
  the token: do not run `mcp list` again. Stop and handle it as above, then verify once.

### Pi

```bash
pi mcp add gbrain -l --url "$GBRAIN_MCP_URL" --bearer-token-env-var GBRAIN_TOKEN
pi mcp list                    # expect: gbrain: connected, 8 tools
```

- `-l` writes `.pi/mcp.json` in this project.
- Pi ignores it until the project is trusted. If `pi mcp list` says *not trusted*, ask the human to
  start `pi` in this directory once and accept the trust prompt, then verify again.

### Grok Build

```bash
grok mcp add --help            # confirm the --url / --header syntax of this version first
grok mcp add gbrain -s project --url "$GBRAIN_MCP_URL" --header 'Authorization: Bearer ${GBRAIN_TOKEN}'
grok mcp doctor --json         # gbrain must appear; check its "source" field
```

- `-s project` writes `./.grok/config.toml`. Values are stored verbatim, so keep the
  `${GBRAIN_TOKEN}` reference: never the token itself. If `--help` shows a different header form
  (e.g. `KEY=VALUE`), use that.
- Grok also picks up a Claude Code `-s project` `.mcp.json`, but only in folders the human has
  trusted in Grok.

### Hermes (v0.23 or newer)

Hermes speaks HTTP MCP natively; check with `hermes --version`. If it is older, stop and tell the
human it needs an upgrade. Hermes has **no per-project MCP config**, so **ask** which option they want:

- **(a) Default profile.** Every Hermes session gets the brain. The token still limits what it can
  see.
- **(b) Dedicated profile for this project.** Create it with `hermes profile create <project-name>`,
  then use `hermes -p <project-name>` when working here.

Back up the profile's `config.yaml`, then merge into its `mcp_servers:` (keep existing servers):

```yaml
mcp_servers:
  gbrain:
    url: "<GBRAIN_MCP_URL>"
    headers:
      Authorization: "Bearer ${GBRAIN_TOKEN}"
    connect_timeout: 60
    enabled: true
```

- Put `GBRAIN_TOKEN=<token>` into the profile's `.env`: `~/.hermes/.env` for the default profile,
  or `~/.hermes/profiles/<name>/.env`. Hermes resolves `${GBRAIN_TOKEN}` from there, not from your
  shell.
- Do it without the token touching the command line or chat:
  `printf 'GBRAIN_TOKEN=%s\n' "$(cat ~/.config/gbrain/token)" >> <profile>/.env && chmod 600 <profile>/.env`
  (only if the line isn't already there).
- Verify: `hermes mcp test gbrain` (add `-p <name>` for a profile). Expect the tool list. If you see
  `${GBRAIN_TOKEN} … is not set`, the `.env` line is missing.

## 3. Make this project's agents read the memory first

Registering the server only makes the tools available. Agents use them when told to. Add the
block below to **every instruction file the configured harnesses read in this project**:

| Harness | Reads (project) |
|---|---|
| Claude Code | `CLAUDE.md` (or `CLAUDE.local.md` if it must stay uncommitted) |
| Codex, OpenCode, Pi | `AGENTS.md` |
| Hermes | the **first** of `.hermes.md` → `AGENTS.override.md` → `AGENTS.md` → `CLAUDE.md` |
| Grok Build | check `grok --help` / its docs for the project instructions file (often `AGENTS.md`) |

- If a file exists, append the block between its markers, or replace an older gbrain block. If a
  needed file doesn't exist, create it.
- **Ask** before committing. It contains no secrets and helps every collaborator, but it changes
  files in the repo.
- Never create `AGENTS.override.md` just for this: Hermes and Codex load it *instead of*
  `AGENTS.md`.

```markdown
<!-- gbrain:start -->
## Shared memory (gbrain): read it before you start

This project shares memory with the research group through the `gbrain` MCP server
(source: {{GBRAIN_SOURCE}}). It holds earlier findings, decisions, dead ends and full session
transcripts from every collaborator and harness.

**Before starting any new task, and before exploring a new scenario, approach, hypothesis, bug or
experiment, query gbrain first:**
1. At the start of a session (and after compaction), call `context_pack`.
2. Search with the task's concrete terms (component names, error strings, offsets, hypothesis):
   - `search` for exact tokens;
   - `query` for concepts;
   - `recall` with `query` for saved facts.
3. Read the best hits with `get_page`, including earlier conversation transcripts.
4. Briefly tell the user what is already known: what was tried, decided, ruled out or found,
   citing page slugs. Or say plainly that nothing relevant exists.
5. Don't repeat work the brain shows was done or ruled out unless the user asks. Build on it instead.

If gbrain is unreachable, say so once and continue without it.

**Writing:** when the user states a durable decision or finding, or a scenario concludes, offer to
`remember` it: one or two lines, with the evidence or where it came from. Never store secrets,
credentials or personal data. Everything written here is readable by every collaborator on this
source.
<!-- gbrain:end -->
```

## 4. Propose sending this project's previous transcripts

Do this only after step 2 works. Everything up to the upload is local and read-only, or happens
in a temp directory.

1. **Scan** (read-only): `python3 "$H" scan --project "$PROJECT"`. It lists this project's sessions
   per harness (date, id, size, first prompt). It finds them by each session's working directory:
   - Claude Code: `~/.claude/projects/`
   - Codex: `~/.codex/sessions/`
   - Grok Build: `~/.grok/sessions/`
   - Hermes: `~/.hermes/state.db` and profiles
   - Pi: `~/.pi/agent/sessions/`
   - OpenCode: `~/.local/share/opencode/opencode.db`
2. **Present** a short summary: count and date range per harness, plus any flags:
   - `automated/cron runs`: scheduled jobs, often hundreds of near-identical runs.
   - `TOO LARGE`: over gbrain's 50 MB per-session limit. Always skipped.
   - `no gbrain adapter`: Pi and OpenCode. They can be converted; see below.
3. **Explain** what happens on the server:
   - Only user and assistant text is kept. Tool calls, tool output, reasoning and system prompts
     are dropped.
   - Common secret patterns are redacted, but that is not a guarantee. Suggest the human skims the
     titles.
   - The result is readable by the whole group, and only the brain owner can delete it.
4. **Ask** what to send. Every answer maps to a flag:
   - Which harnesses: `--harness claude-code,codex,...` (default: all found).
   - Include automated runs? Default no: `--skip-automated`.
   - Convert Pi/OpenCode sessions? `--convert-unsupported`. They become pages labelled with source
     `pi` / `opencode`.
   - Leave out specific sessions: `--exclude <id> ...`.
   - Only recent ones: `--since YYYY-MM-DD` (and/or `--until YYYY-MM-DD`).
   - Specific Hermes cron jobs, threads or sessions: see 4.4a.

   **4.4a Hermes cron jobs, threads and single sessions.** Offer this when the scan shows
   automated runs, or when the human mentions a scheduled job or a particular conversation.
   Scheduled jobs often run in a *different* directory from the project (a watcher started
   from a workspace or home directory, say), so the project scan can miss them.
   1. Show the cron jobs: `python3 "$H" hermes jobs`. For each job it gives runs, runs with text,
      `[SILENT]` runs, date range, working dir, and whether the job still exists.
   2. **Ask** which jobs belong to this project's source. Then preview the runs of each chosen job:
      `python3 "$H" hermes runs --job "<name>" [--since D] [--until D] [--grep TEXT] [--last N] [--skip-silent]`.
      Each line shows a run's date, id, size and the start of its final report. Jobs that run every
      minute produce hundreds of near-unique runs, so suggest narrowing:
      - a date window;
      - `--grep` for runs that mention what matters (repeatable, OR);
      - `--last N` per job;
      - `--skip-silent`.
   3. Conversations: `python3 "$H" hermes threads` (this project) or `--all`. A thread is a session
      plus its continuations (compaction, handoffs, sub-agents). Its root id selects the whole
      chain. A `chat_id` selects a whole chat (e.g. a Telegram topic).
   4. Select with:
      - `--hermes-job "<name>"`: a glob like `'nightly-*'` is allowed;
      - `--hermes-thread <root id | any session id in it | chat_id>`;
      - `--hermes-session <id or ≥8-char prefix>`.

      All three can be repeated, and they can be combined with the narrowing flags above. The
      narrowing flags apply to cron runs. Picked threads and sessions always come whole. These
      selectors are **explicit**: they are not limited to the project directory, so confirm with
      the human that each pick belongs in `GBRAIN_SOURCE`.

   Each job and thread becomes its own slice, named after its exact session set. Re-sending the
   same selection is free, and later selections never shadow earlier ones.
5. **Stage** into a private temp dir (0700):
   ```bash
   OUT="$(mktemp -d)/gbrain-stage"
   python3 "$H" stage --project "$PROJECT" --out "$OUT" <flags from 4.4>
   ```
   Report its summary line, e.g. `staged …: claude-code=12, hermes=3`.
6. **Dry run**: `python3 "$H" upload --out "$OUT" --dest "$GBRAIN_UPLOAD" --dry-run`. Show the file
   list, then **ask** for the final "yes".
7. **Upload**: `python3 "$H" upload --out "$OUT" --dest "$GBRAIN_UPLOAD"`.
   - `Permission denied (publickey)`: the brain owner hasn't registered this person's upload key
     yet. Stop, and tell the human to send the owner their public key (step 5.1 creates a
     dedicated one).
   - The upload key can only write into the person's own inbox. That is expected: no reads, no
     shell.
8. **Clean up**: `rm -rf "$(dirname "$OUT")"`.
9. **Tell the human**:
   - The server ingests within about 15–20 minutes. A file is processed once it has been unchanged
     for 2 minutes.
   - Failed files are retried, and the server's health check flags them to the owner.
   - Re-running steps 4.1–4.7 later is safe: unchanged sessions are skipped, and grown sessions
     update in place.
   - To confirm, ask an agent with the gbrain tools to search for a distinctive phrase from one of
     the sessions.

## 5. Keep it in sync every hour

Propose this after step 4, or on its own if the backfill was skipped. Hourly runs send only
sessions with **new activity** since the last successful run (minus a 15-minute overlap), so a
long session keeps updating. The marker only advances when the upload succeeds, so missed hours
are caught up automatically.

1. **Upload key that works without a prompt** (needed for scheduled runs; once per machine):
   ```bash
   ssh-keygen -t ed25519 -N '' -C "gbrain-upload-$PERSON" -f ~/.ssh/gbrain_upload
   cat >> ~/.ssh/config <<'CFG'

   Host gbrain-upload
     HostName {{GBRAIN_SSH_HOST}}
     User {{GBRAIN_SSH_USER}}
     IdentityFile ~/.ssh/gbrain_upload
     IdentitiesOnly yes
   CFG
   ```
   - Skip whatever already exists (key file, `Host gbrain-upload` block).
   - A key with no passphrase is acceptable here: the server pins it to `rrsync -wo` on the
     person's own inbox (write-only, no shell, no reads, no deletes).
   - The human sends `~/.ssh/gbrain_upload.pub` to the brain owner, who registers it with
     `inbox-key.sh add <person> <file>`. The owner does the same for their own machines.
   - Pin the server's host key **only if its fingerprint matches** `GBRAIN_HOSTKEY`:
     ```bash
     K="$(mktemp)"; ssh-keyscan -t ed25519 {{GBRAIN_SSH_HOST}} 2>/dev/null > "$K"
     ssh-keygen -lf "$K"                      # must print the GBRAIN_HOSTKEY fingerprint
     ```
     If it matches, `cat "$K" >> ~/.ssh/known_hosts`. If it doesn't, **do not append it**: stop
     and tell the human (wrong host, or something is intercepting the connection). `rm -f "$K"`
     either way.
   - Test, once the owner confirms the key is registered: `ssh -o BatchMode=yes gbrain-upload true`.
     - Exit status 0 with no output, or `rrsync error: SSH_ORIGINAL_COMMAND does not run rsync`
       (older rrsync), means the key works. Any other command, e.g. `ssh gbrain-upload id`, must
       print that rrsync error: the key cannot run anything but uploads.
     - `Permission denied (publickey)` means the key isn't registered yet.
2. **Ask** what to keep synced. Each choice becomes one entry; entries accumulate per machine in
   `~/.config/gbrain/sync.json`.
   - **This project** (same selection flags as the backfill):
     `python3 "$H" sync add --name "<project>" --dest "$GBRAIN_UPLOAD" --project "$PROJECT" [--harness …] [--skip-automated] [--convert-unsupported]`
   - **Each Hermes cron job or thread** chosen in 4.4a, one entry each. An entry with Hermes
     selectors syncs only that selection:
     `python3 "$H" sync add --name "<job>" --dest "$GBRAIN_UPLOAD" --hermes-job "<job>" [--skip-silent] [--grep TEXT]`
     `python3 "$H" sync add --name "<thread>" --dest "$GBRAIN_UPLOAD" --hermes-thread <root id>`
   - A new entry starts from "now": the backfill already covered the past. If there was no
     backfill and recent history should go too, add `--backfill-hours N`.
3. **Try it**: `python3 "$H" sync run --dry-run`, then `python3 "$H" sync run`. Each line says
   `uploaded …`, `nothing changed …` or `UPLOAD FAILED … (will retry next run)`.
4. **Schedule it** (**ask**: it installs a per-user background job):
   `python3 "$H" schedule install`. This copies the helper to
   `~/.local/share/gbrain/gbrain_project.py` and runs `sync run` every hour:
   - macOS: a launchd agent `com.gbrain.sync`, log `~/Library/Logs/gbrain-sync.log`;
   - Linux: a systemd user timer `gbrain-sync.timer`, or a crontab entry if user systemd isn't
     available.

   Check with `python3 "$H" schedule status`. From now on, use the installed copy for sync commands.
5. **Stopping**: `schedule remove` stops all syncing on this machine; `sync remove --name <entry>`
   drops one selection. Nothing already ingested is affected.

## 6. Report back

End with a short report:
- The project dir.
- Each harness configured: the file it wrote, and the verify result (✔ / ✘ plus the error).
- The instruction files that received the gbrain block, and whether they were committed.
- Anything written outside the project (global config, shell profile, Hermes `.env`, `~/.ssh/config`,
  sync config, scheduled job).
- What was uploaded (counts per harness), what was skipped and why.
- The sync entries, and whether the hourly job is installed.
- What the human still has to do:
  - Restart harnesses so they load the MCP server and the new instructions.
  - Accept trust prompts in Pi, Codex or Grok.
  - Send `~/.ssh/gbrain_upload.pub` to the brain owner, if not done.

## Appendix: gbrain_project.py

Write this verbatim to `$H` (step 1.4). Subcommands:
- `check`: MCP handshake, `whoami` and a search, using `$GBRAIN_TOKEN`.
- `scan`: read-only.
- `stage`: copy or convert into `--out`.
- `upload`: a single `rsync -a` to `--dest`.

It never deletes anything from the harness stores.

<!-- BEGIN gbrain_project.py (generated by scripts/build_agent_setup.py — edit scripts/gbrain_project.py) -->
```python
#!/usr/bin/env python3
"""gbrain_project.py — connect check + transcript scan/stage/upload for ONE project (stdlib only).

  python3 gbrain_project.py check  --url URL [--token-env GBRAIN_TOKEN]
  python3 gbrain_project.py scan   [--project DIR] [--harness LIST] [--since YYYY-MM-DD] [--json]
  python3 gbrain_project.py stage  --out DIR [--project DIR] [--harness LIST] [--since D]
                                   [--exclude ID ...] [--convert-unsupported]
  python3 gbrain_project.py upload --out DIR --dest USER@HOST:PATH [--dry-run]
  python3 gbrain_project.py hermes jobs | runs --job NAME | threads [--all]
  python3 gbrain_project.py sync add --name N --dest D <selection flags> | list | remove --name N | run [--dry-run]
  python3 gbrain_project.py schedule install|remove|status [--every 3600]

Hourly sync: `sync add` saves a selection (same flags as stage) with its destination in
~/.config/gbrain/sync.json; `sync run` sends every session with activity since the entry's last
successful run (minus 15 min overlap) and only advances that mark when the upload succeeds.
`schedule install` copies this file to ~/.local/share/gbrain/ and runs `sync run` every hour via
launchd (macOS), a systemd user timer, or cron. Uploads use ssh BatchMode, so the upload key must
work without a prompt (use the dedicated, upload-only key).

Hermes cron/threads: `hermes jobs` lists every cron job seen in the store (runs, silent, cwd, whether
the job still exists); `hermes runs --job NAME` shows each run with its final report; `hermes threads`
lists conversation chains. scan/stage take --hermes-job/--hermes-thread/--hermes-session (explicit
selection, NOT limited to the project dir) narrowed by --since/--until/--grep/--last/--skip-silent.

Only sessions whose working directory is the project dir (or a subdirectory) are touched.
scan is read-only. stage copies (or, for Pi/OpenCode with --convert-unsupported, converts) the
matching sessions into DIR (0700), laid out as <harness>/... for the gbrain inbox. upload sends
DIR in one rsync. Nothing is deleted from the harness stores.

Harnesses: claude-code, codex, grok, hermes (native gbrain formats) and pi, opencode (no gbrain
adapter: converted into the Hermes slice schema with sessions.source = 'pi' / 'opencode').
"""
import argparse, fnmatch, hashlib, json, os, re, shutil, sqlite3, ssl, subprocess, sys, time, urllib.parse, urllib.request, urllib.error
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
NATIVE = ["claude-code", "codex", "grok", "hermes"]
CONVERTED = ["pi", "opencode"]
ALL = NATIVE + CONVERTED
# gbrain rejects a single claude-code / grok session file over 50 MB (codex degrades to head+tail).
SIZE_CAP = {"claude-code": 50 * 1024 * 1024, "grok": 50 * 1024 * 1024}


# ---------------------------------------------------------------- helpers
def norm(p):
    if not p:
        return None
    try:
        return os.path.realpath(os.path.expanduser(str(p)))
    except Exception:
        return os.path.normpath(str(p))


def in_project(cwd, project):
    c = norm(cwd)
    return bool(c) and (c == project or c.startswith(project + os.sep))


def iso(ts):
    """epoch seconds/ms or ISO string -> 'YYYY-MM-DD HH:MM' (UTC)."""
    if ts is None or ts == "":
        return ""
    try:
        if isinstance(ts, (int, float)):
            t = ts / 1000 if ts > 1e11 else ts
            return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d %H:%M")
        return str(ts)[:16].replace("T", " ")
    except Exception:
        return str(ts)[:16]


def epoch(ts):
    if ts is None or ts == "":
        return None
    if isinstance(ts, (int, float)):
        return ts / 1000 if ts > 1e11 else float(ts)
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def clip(s, n=70):
    s = re.sub(r"\s+", " ", str(s or "")).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def jsonl(path, limit=None):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if limit is not None and i >= limit:
                return
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except Exception:
                continue


def text_of(content):
    """content as str | [{type:text,text}|{type:input_text,text}|...] -> plain text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for c in content:
            if isinstance(c, dict) and c.get("type") in ("text", "input_text", "output_text") and isinstance(c.get("text"), str):
                out.append(c["text"])
        return "\n".join(out)
    return ""


def first_prompt(texts):
    for t in texts:
        t = (t or "").strip()
        if t and not t.startswith("<") and not t.startswith("#") and len(t) > 3:
            return t
    return ""


def ro_sqlite(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


# ---------------------------------------------------------------- discovery
def scan_claude(project, since):
    root = HOME / ".claude" / "projects"
    slug = re.sub(r"[^A-Za-z0-9]", "-", project)
    out = []
    if not root.is_dir():
        return out
    for d in root.iterdir():
        if not d.is_dir() or not d.name.startswith(slug):
            continue
        for f in d.glob("*.jsonl"):
            cwd, started, prompts = None, None, []
            for e in jsonl(f, 400):
                cwd = cwd or e.get("cwd")
                started = started or e.get("timestamp")
                if e.get("type") == "user" and not e.get("isMeta") and len(prompts) < 5:
                    prompts.append(text_of((e.get("message") or {}).get("content")))
            if not in_project(cwd, project):
                continue
            out.append(dict(harness="claude-code", id=f.stem, files=[str(f)], started=started,
                            bytes=f.stat().st_size, title=first_prompt(prompts), rel=f"{d.name}/{f.name}",
                            updated=f.stat().st_mtime))
    return out


def scan_codex(project, since):
    root = Path(os.environ.get("CODEX_HOME", HOME / ".codex")) / "sessions"
    out = []
    if not root.is_dir():
        return out
    for f in root.rglob("rollout-*.jsonl"):
        meta, prompts = None, []
        for e in jsonl(f, 60):
            if e.get("type") == "session_meta" and meta is None:
                meta = e.get("payload") or {}
            p = e.get("payload") or {}
            if e.get("type") == "response_item" and p.get("type") == "message" and p.get("role") == "user":
                prompts.append(text_of(p.get("content")))
        if not meta or not in_project(meta.get("cwd"), project):
            continue
        out.append(dict(harness="codex", id=meta.get("id") or f.stem, files=[str(f)],
                        started=meta.get("timestamp"), bytes=f.stat().st_size,
                        title=first_prompt(prompts), rel=str(f.relative_to(root)), updated=f.stat().st_mtime))
    return out


def scan_grok(project, since):
    root = Path(os.environ.get("GROK_HOME", HOME / ".grok")) / "sessions"
    out = []
    if not root.is_dir():
        return out
    for d in root.iterdir():
        if not d.is_dir():
            continue
        for chat in d.glob("*/chat_history.jsonl"):
            sdir = chat.parent
            summary = {}
            try:
                summary = json.loads((sdir / "summary.json").read_text())
            except Exception:
                pass
            cwd = (summary.get("info") or {}).get("cwd") or urllib.parse.unquote(d.name)
            if not in_project(cwd, project):
                continue
            files = [str(chat)] + ([str(sdir / "summary.json")] if (sdir / "summary.json").exists() else [])
            out.append(dict(harness="grok", id=sdir.name, files=files,
                            started=summary.get("created_at"), bytes=sum(Path(x).stat().st_size for x in files),
                            title=summary.get("generated_title") or "", rel=f"{d.name}/{sdir.name}",
                            updated=max(Path(x).stat().st_mtime for x in files)))
    return out


def hermes_stores():
    base = Path(os.environ.get("HERMES_HOME", HOME / ".hermes"))
    stores = [base / "state.db"] + sorted((base / "profiles").glob("*/state.db"))
    return [s for s in stores if s.is_file()]


# ---------------------------------------------------------------- Hermes: cron jobs, threads, explicit selection
JOB_TITLE = re.compile(r"^(.*) · [A-Z][a-z]{2} \d{1,2} \d{1,2}:\d{2}$")   # "nightly-sync · Nov 09 21:42"


def hermes_profile(store):
    p = Path(store).parent
    return "default" if p.parent.name != "profiles" else p.name


def cron_jobs(store):
    """{job_id: job} from the cron/jobs.json next to this store (current jobs only)."""
    try:
        d = json.loads((Path(store).parent / "cron" / "jobs.json").read_text())
    except Exception:
        return {}
    jobs = d if isinstance(d, list) else d.get("jobs", d)
    jobs = list(jobs.values()) if isinstance(jobs, dict) else jobs
    return {j.get("id"): j for j in jobs if isinstance(j, dict) and j.get("id")}


def job_of(sid, title, jobs):
    m = JOB_TITLE.match(title or "")
    if m:
        return m.group(1)
    m = re.match(r"cron_([0-9a-f]{12})_", sid or "")
    if m:
        return (jobs.get(m.group(1)) or {}).get("name") or f"job:{m.group(1)}"
    return "(untitled)"


def like_prefix(path):
    """LIKE pattern for 'path/...' with the wildcard characters escaped (use with ESCAPE backslash)."""
    return path.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "/%"


def hermes_rows(store, where="1=1", params=(), stats=True):
    """Sessions of one Hermes store as records. Session-level columns only (cheap); message
    statistics are filled by hermes_stats(), which callers run after their cheap filters."""
    con = ro_sqlite(store)
    cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
    col = lambda c: f"s.{c}" if c in cols else "NULL"
    rows = con.execute(
        f"SELECT s.id, coalesce({col('title')},''), {col('started_at')}, coalesce({col('cwd')},''), "
        f"coalesce({col('source')},''), {col('parent_session_id')}, {col('chat_id')}, {col('thread_id')}, "
        f"{col('ended_at')}, {col('last_activity_at')} FROM sessions s WHERE {where}", params).fetchall()
    con.close()
    jobs = cron_jobs(store)
    out = []
    for sid, title, started, cwd, source, parent, chat, thread, ended, activity in rows:
        auto = source == "cron"
        hint = max([e for e in (epoch(started), epoch(ended), epoch(activity)) if e] or [0]) or None
        out.append(dict(harness="hermes", id=sid, files=[str(store)], store=str(store),
                        profile=hermes_profile(store), started=started, bytes=0, title=title,
                        messages=None, cwd=cwd, source=source, automated=auto,
                        job=job_of(sid, title, jobs) if auto else None, silent=False, last="",
                        parent=parent, chat=chat, thread=thread, bucket="project",
                        updated=hint, activity_hint=hint if "last_activity_at" in cols else None))
    if stats:
        hermes_stats(out)
    return out


def hermes_stats(recs):
    """Fill messages / bytes / updated / last / silent from the messages table, in place."""
    by_store = defaultdict(list)
    for r in recs:
        if r["messages"] is None:
            by_store[r["store"]].append(r)
    for store, rs in by_store.items():
        con = ro_sqlite(store)
        by_id = {r["id"]: r for r in rs}
        ids = list(by_id)
        for i in range(0, len(ids), 400):
            chunk = ids[i:i + 400]
            q = ",".join("?" * len(chunk))
            for sid, n, nbytes, last_ts in con.execute(
                    "SELECT session_id, sum(CASE WHEN role IN ('user','assistant') AND coalesce(content,'') <> '' "
                    "THEN 1 ELSE 0 END), coalesce(sum(length(content)),0), max(timestamp) "
                    f"FROM messages WHERE session_id IN ({q}) GROUP BY session_id", chunk):
                r = by_id[sid]
                r["messages"], r["bytes"] = n or 0, nbytes
                r["updated"] = epoch(last_ts) or r["updated"] or epoch(r["started"])
        for r in rs:
            if r["messages"] is None:
                r["messages"] = 0
            elif r["automated"] and r["messages"]:
                row = con.execute(
                    "SELECT substr(content,1,400) FROM messages WHERE session_id = ? AND role = 'assistant' "
                    "AND coalesce(content,'') <> '' ORDER BY timestamp DESC, id DESC LIMIT 1", (r["id"],)).fetchone()
                r["last"] = (row[0] if row else "") or ""
                r["silent"] = r["last"].strip().startswith("[SILENT]")
        con.close()
    return recs


def scan_hermes(project, since):
    out = []
    for store in hermes_stores():
        try:
            recs = hermes_rows(store, "s.cwd = ? OR s.cwd LIKE ? ESCAPE '\\'", (project, like_prefix(project)),
                               stats=False)
        except Exception as e:
            print(f"warn: cannot read {store}: {e}", file=sys.stderr)
            continue
        out += [r for r in recs if in_project(r["cwd"], project)]
    return out


def slug(x):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", str(x)).strip("-")[:48] or "x"


def resolve_ids(token, by_id):
    """Exact session id, or a unique prefix of >= 8 chars."""
    if token in by_id:
        return [token]
    if len(token) < 8:
        return []
    return [i for i in by_id if i.startswith(token)]


def grep_ids(store, ids, patterns):
    """Session ids (from ids) with at least one message containing any pattern (case-insensitive)."""
    if not patterns or not ids:
        return set(ids)
    con = ro_sqlite(store)
    hit, ids = set(), list(ids)
    like = " OR ".join("lower(content) LIKE ? ESCAPE '\\'" for _ in patterns)
    pats = ["%" + p.lower().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%" for p in patterns]
    for i in range(0, len(ids), 400):
        chunk = ids[i:i + 400]
        q = ",".join("?" * len(chunk))
        hit.update(r[0] for r in con.execute(
            f"SELECT DISTINCT session_id FROM messages WHERE session_id IN ({q}) AND ({like})", chunk + pats))
    con.close()
    return hit


def hermes_filter(recs, since=None, until=None, grep=(), last=None, skip_silent=False, skip_automated=False,
                  changed_since=None):
    """Narrowing for Hermes records: dates, text, silent/automated, last N per cron job, activity.
    Explicitly picked threads/chats/sessions are never narrowed (only empty sessions are dropped).
    Cheap session-level filters run first; message statistics are read only for what survives."""
    is_pick = lambda r: r["bucket"].startswith(("thread-", "chat-", "sessions"))
    se, ue = epoch(since) if since else None, epoch(until) if until else None
    if ue and until and len(until) == 10:
        ue += 86400                                   # --until YYYY-MM-DD includes that day
    cand = []
    for r in recs:
        if not is_pick(r):
            e = epoch(r.get("started"))
            if (se and e and e < se) or (ue and e and e >= ue) or (skip_automated and r["automated"]):
                continue
            # last_activity_at says nothing happened since the last sync: skip without reading messages
            if changed_since and r.get("activity_hint") and r["activity_hint"] < changed_since - 3600:
                continue
        cand.append(r)
    hermes_stats(cand)
    cand = [r for r in cand if r["messages"]]
    picked = [r for r in cand if is_pick(r)]
    keep = [r for r in cand if not is_pick(r) and not (skip_silent and r["silent"])]
    if grep:
        by_store = defaultdict(list)
        for r in keep:
            by_store[r["store"]].append(r["id"])
        hits = set()
        for store, ids in by_store.items():
            hits |= grep_ids(store, ids, grep)
        keep = [r for r in keep if r["id"] in hits]
    if last:
        # --last limits cron runs per job only; a picked thread or session list always comes whole.
        by_job, rest = defaultdict(list), []
        for r in keep:
            if r["automated"]:
                by_job[(r["store"], r["job"])].append(r)
            else:
                rest.append(r)
        keep = rest + [r for grp in by_job.values()
                       for r in sorted(grp, key=lambda x: epoch(x.get("started")) or 0)[-last:]]
    if changed_since:
        # sessions: only those with new activity; a picked thread/chat is resent whole if any member changed
        keep = [r for r in keep if (r.get("updated") or 0) >= changed_since]
        active = {(r["store"], r["bucket"]) for r in picked if (r.get("updated") or 0) >= changed_since}
        picked = [r for r in picked if (r["store"], r["bucket"]) in active]
    seen = {(r["store"], r["id"]) for r in keep}
    return keep + [r for r in picked if (r["store"], r["id"]) not in seen]


def select_hermes(jobs=(), threads=(), sessions=()):
    """Explicit selection across every Hermes store, NOT limited to a project directory.
    jobs: cron job names (glob ok); threads: a session id (its whole continuation chain) or a
    chat_id / thread_id (every session in that chat); sessions: ids or unique prefixes."""
    picked, problems = {}, []
    for store in hermes_stores():
        recs = hermes_rows(store, stats=False)
        by_id = {r["id"]: r for r in recs}
        kids = defaultdict(list)
        for r in recs:
            if r["parent"]:
                kids[r["parent"]].append(r["id"])
        def take(r, bucket):
            r = dict(r, bucket=bucket)
            picked.setdefault((store, r["id"]), r)
        for name in jobs:
            m = [r for r in recs if r["automated"] and fnmatch.fnmatch((r["job"] or "").lower(), name.lower())]
            for r in m:
                take(r, f"cron-{slug(r['job'])}")
            if not m and store == hermes_stores()[0]:
                problems.append(f"no cron runs for job '{name}' (see: hermes jobs)")
        for t in threads:
            ids = resolve_ids(t, by_id)
            if len(ids) > 1:
                problems.append(f"'{t}' matches {len(ids)} sessions; give more characters"); continue
            if ids:
                root = ids[0]
                while by_id.get(root, {}).get("parent") in by_id:
                    root = by_id[root]["parent"]
                todo, chain = [root], []
                while todo:
                    x = todo.pop(); chain.append(x); todo += kids.get(x, [])
                for x in chain:
                    take(by_id[x], f"thread-{slug(root)[:24]}")
                continue
            grp = [r for r in recs if t in (r["chat"], r["thread"])]
            for r in grp:
                take(r, f"chat-{slug(t)[:24]}")
            if not grp and store == hermes_stores()[0]:
                problems.append(f"no session, chat_id or thread_id matches '{t}' (see: hermes threads)")
        for t in sessions:
            ids = resolve_ids(t, by_id)
            if len(ids) == 1:
                take(by_id[ids[0]], "sessions")
            elif len(ids) > 1:
                problems.append(f"'{t}' matches {len(ids)} sessions; give more characters")
            elif store == hermes_stores()[0]:
                problems.append(f"no session id matches '{t}'" + (" (prefix needs >= 8 characters)" if len(t) < 8 else ""))
    return list(picked.values()), problems


def hermes_list(kind, a):
    stores = hermes_stores()
    if not stores:
        print("no Hermes store found (HERMES_HOME / ~/.hermes/state.db)"); return 1
    if kind == "jobs":
        print(f"{'job':34} {'state':9} {'runs':>5} {'used':>5} {'silent':>6}  {'first':16}  {'last':16}  cwd")
        for store in stores:
            current = {j.get("name"): j for j in cron_jobs(store).values()}
            groups = defaultdict(list)
            for r in hermes_rows(store, "s.source = 'cron'"):
                groups[r["job"]].append(r)
            for job, rs in sorted(groups.items(), key=lambda x: -len(x[1])):
                st = "-" if job == "(untitled)" else "deleted"
                if job in current:
                    st = "enabled" if current[job].get("enabled", True) and not current[job].get("paused_at") else "paused"
                used = [r for r in rs if r["messages"]]
                dates = sorted(epoch(r["started"]) or 0 for r in used) or [0]
                cwds = sorted({r["cwd"] or "-" for r in rs})
                name = job if hermes_profile(store) == "default" else f"{hermes_profile(store)}:{job}"
                print(f"{clip(name, 34):34} {st:9} {len(rs):5} {len(used):5} {sum(r['silent'] for r in rs):6}  "
                      f"{iso(dates[0]):16}  {iso(dates[-1]):16}  {clip(', '.join(cwds), 60)}")
        print("\nused = runs with conversation text (empty runs are never imported). Select with --hermes-job NAME.")
        return 0
    if kind == "runs":
        recs, problems = select_hermes(jobs=[a.job])
        recs = hermes_filter(recs, a.since, a.until, a.grep, a.last, a.skip_silent)
        for p in problems:
            print("note:", p)
        for r in sorted(recs, key=lambda x: epoch(x.get("started")) or 0):
            flag = "SILENT " if r["silent"] else ""
            print(f"  {iso(r['started']):16}  {r['id'][:28]:28}  {r['messages']:4} msg  {flag}{clip(r['last'], 80)}")
        print(f"\n{len(recs)} run(s). Narrow with --since/--until/--grep/--last/--skip-silent, or pick ids with --hermes-session.")
        return 0
    if kind == "threads":
        project = None if a.all else norm(a.project)
        for store in stores:
            recs = [r for r in hermes_rows(store, "coalesce(s.source,'') <> 'cron'") if r["messages"]]
            by_id = {r["id"]: r for r in recs}
            def root_of(r):
                while r.get("parent") in by_id:
                    r = by_id[r["parent"]]
                return r["id"]
            chains = defaultdict(list)
            for r in recs:
                chains[root_of(r)].append(r)
            rows = []
            for root, rs in chains.items():
                if project and not any(in_project(r["cwd"], project) for r in rs):
                    continue
                if a.since and max(epoch(r["started"]) or 0 for r in rs) < (epoch(a.since) or 0):
                    continue
                rs.sort(key=lambda r: epoch(r["started"]) or 0)
                rows.append((rs, root))
            print(f"{'root session':28} {'n':>3} {'source':9} {'chat_id':22} {'first':16}  {'last':16}  title")
            for rs, root in sorted(rows, key=lambda x: epoch(x[0][-1]["started"]) or 0):
                r0 = rs[0]
                print(f"{root[:28]:28} {len(rs):3} {clip(r0['source'], 9):9} {clip(r0['chat'] or '-', 22):22} "
                      f"{iso(r0['started']):16}  {iso(rs[-1]['started']):16}  {clip(r0['title'] or r0['last'], 50)}")
            print(f"\n{len(rows)} thread(s){'' if a.all else ' in ' + project}. Select a chain with --hermes-thread <root id>, "
                  "a whole chat with --hermes-thread <chat_id>.")
        return 0


def scan_pi(project, since):
    root = Path(os.environ.get("PI_CODING_AGENT_DIR", HOME / ".pi" / "agent")) / "sessions"
    out = []
    if not root.is_dir():
        return out
    for f in root.glob("*/*.jsonl"):
        head = next(jsonl(f, 1), None) or {}
        if head.get("type") != "session" or not in_project(head.get("cwd"), project):
            continue
        prompts = []
        for e in jsonl(f, 300):
            m = e.get("message") or {}
            if e.get("type") == "message" and m.get("role") == "user":
                prompts.append(text_of(m.get("content")))
                if len(prompts) >= 3:
                    break
        out.append(dict(harness="pi", id=head.get("id") or f.stem, files=[str(f)],
                        started=head.get("timestamp"), bytes=f.stat().st_size, title=first_prompt(prompts),
                        updated=f.stat().st_mtime))
    return out


def opencode_db():
    base = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local" / "share"))
    p = base / "opencode" / "opencode.db"
    return p if p.is_file() else None


def scan_opencode(project, since):
    db = opencode_db()
    out = []
    if not db:
        return out
    con = ro_sqlite(db)
    seen = set()
    for table in ("session_v2", "session"):
        try:
            rows = con.execute(f"SELECT id, title, directory, time_created, coalesce(time_updated, time_created) FROM {table} "
                               f"WHERE parent_id IS NULL AND (directory = ? OR directory LIKE ? ESCAPE '\\')",
                               (project, like_prefix(project))).fetchall()
        except sqlite3.Error:
            continue
        for sid, title, directory, created, updated in rows:
            if sid in seen or not in_project(directory, project):
                continue
            seen.add(sid)
            out.append(dict(harness="opencode", id=sid, files=[str(db)], started=created, bytes=0,
                            title=title or "", table=table, updated=epoch(updated)))
    con.close()
    return out


SCANNERS = {"claude-code": scan_claude, "codex": scan_codex, "grok": scan_grok,
            "hermes": scan_hermes, "pi": scan_pi, "opencode": scan_opencode}


def discover(project, harnesses, since, exclude=(), skip_automated=False, changed_since=None):
    since_e = epoch(since) if since else None
    sessions = []
    for h in harnesses:
        for s in SCANNERS[h](project, since):
            e = epoch(s.get("started"))
            if since_e and e and e < since_e:
                continue
            if s["id"] in exclude or (skip_automated and s.get("automated")):
                continue
            if changed_since and (s.get("updated") or 0) < changed_since:
                continue
            sessions.append(s)
    sessions.sort(key=lambda s: (s["harness"], epoch(s.get("started")) or 0))
    return sessions


# ---------------------------------------------------------------- hermes-schema writer (slices + conversions)
SLICE_SCHEMA = """
CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, display_name TEXT, title TEXT,
                       started_at REAL, cwd TEXT, model TEXT);
CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
                       timestamp REAL, tool_call_id TEXT, tool_name TEXT);
"""


def new_slice(path):
    if path.exists():
        path.unlink()
    con = sqlite3.connect(path)
    con.executescript(SLICE_SCHEMA)
    return con


def write_session(con, sid, source, title, started, cwd, model, msgs):
    """msgs: [(role, text, epoch_ts)] — only non-empty user/assistant text is kept."""
    kept = [(r, t, ts) for r, t, ts in msgs if r in ("user", "assistant") and (t or "").strip()]
    if not kept:
        return 0
    con.execute("INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?,?,?)",
                (sid, source, None, title, started or kept[0][2], cwd, model))
    for r, t, ts in kept:
        con.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
                    (sid, r, t, ts))
    return len(kept)


def stage_hermes(sessions, out):
    """One slice per (store, bucket). The file name carries a hash of the exact session set: the
    server's `--since last` watermark is keyed on the file path, so a different selection must
    never reuse a name (it would silently skip older sessions). Re-staging the same set reuses the
    name; gbrain's content hashing makes repeats free."""
    groups = defaultdict(list)
    for s in sessions:
        groups[(s["store"], s.get("bucket") or "project")].append(s["id"])
    n = 0
    for (store, bucket), ids in sorted(groups.items()):
        ids = sorted(set(ids))
        h = hashlib.sha256("\n".join(ids).encode()).hexdigest()[:10]
        prof = hermes_profile(store)
        name = f"{'' if prof == 'default' else slug(prof) + '-'}{bucket}-{h}.db"
        dst = out / "hermes" / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        con = new_slice(dst)
        src = ro_sqlite(store)
        cols = {r[1] for r in src.execute("PRAGMA table_info(sessions)")}
        pick = lambda c: c if c in cols else "NULL"
        for i in range(0, len(ids), 400):
            chunk = ids[i:i + 400]
            q = ",".join("?" * len(chunk))
            for row in src.execute(f"SELECT id, {pick('source')}, {pick('display_name')}, {pick('title')}, "
                                   f"{pick('started_at')}, {pick('cwd')}, {pick('model')} FROM sessions WHERE id IN ({q})", chunk):
                con.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?)", row)
            for row in src.execute(f"SELECT id, session_id, role, content, timestamp, tool_call_id, tool_name "
                                   f"FROM messages WHERE session_id IN ({q})", chunk):
                con.execute("INSERT INTO messages VALUES (?,?,?,?,?,?,?)", row)
        con.commit(); con.close(); src.close()
        n += len(ids)
    return n


def stage_pi(sessions, out, project_name):
    dst = out / "hermes" / f"pi-{project_name}.db"
    dst.parent.mkdir(parents=True, exist_ok=True)
    con = new_slice(dst)
    n = 0
    for s in sessions:
        f = s["files"][0]
        msgs, model, cwd = [], None, None
        for e in jsonl(f):
            if e.get("type") == "session":
                cwd = e.get("cwd")
            elif e.get("type") == "model_change":
                model = e.get("modelId") or model
            elif e.get("type") == "message":
                m = e.get("message") or {}
                msgs.append((m.get("role"), text_of(m.get("content")), epoch(e.get("timestamp"))))
        if write_session(con, f"pi-{s['id']}", "pi", clip(s.get("title"), 120), epoch(s.get("started")), cwd, model, msgs):
            n += 1
    con.commit(); con.close()
    if n == 0:
        dst.unlink()
    return n


def stage_opencode(sessions, out, project_name):
    db = opencode_db()
    dst = out / "hermes" / f"opencode-{project_name}.db"
    dst.parent.mkdir(parents=True, exist_ok=True)
    con = new_slice(dst)
    src = ro_sqlite(db)
    n = 0
    for s in sessions:
        msgs = []
        if s["table"] == "session_v2":
            for typ, data, created in src.execute(
                    "SELECT type, data, time_created FROM session_message WHERE session_id = ? "
                    "AND type IN ('user','assistant') ORDER BY seq", (s["id"],)):
                try:
                    d = json.loads(data)
                except Exception:
                    continue
                txt = d.get("text") if typ == "user" else text_of(d.get("content"))
                msgs.append((typ, txt, epoch(created)))
        else:
            for mid, data, created in src.execute(
                    "SELECT id, data, time_created FROM message WHERE session_id = ? ORDER BY time_created", (s["id"],)):
                try:
                    role = json.loads(data).get("role")
                except Exception:
                    continue
                parts = []
                for (pdata,) in src.execute("SELECT data FROM part WHERE message_id = ? ORDER BY time_created", (mid,)):
                    try:
                        p = json.loads(pdata)
                    except Exception:
                        continue
                    if p.get("type") == "text" and not p.get("synthetic"):
                        parts.append(p.get("text") or "")
                msgs.append((role, "\n".join(parts), epoch(created)))
        if write_session(con, f"opencode-{s['id']}", "opencode", clip(s.get("title"), 120),
                         epoch(s.get("started")), None, None, msgs):
            n += 1
    con.commit(); con.close(); src.close()
    if n == 0:
        dst.unlink()
    return n


def too_big(s):
    cap = SIZE_CAP.get(s["harness"])
    return bool(cap) and any(Path(f).stat().st_size > cap for f in s["files"] if f.endswith(".jsonl"))


def stage(sessions, out, project, convert):
    out.mkdir(parents=True, exist_ok=True)
    os.chmod(out, 0o700)
    os.umask(0o077)
    pname = re.sub(r"[^A-Za-z0-9._-]", "_", Path(project).name) or "project"
    counts = {}
    for s in sessions:
        h = s["harness"]
        if h in ("claude-code", "codex", "grok"):
            if too_big(s):
                print(f"skip {h} {s['id']}: over gbrain's 50 MB per-session limit", file=sys.stderr)
                counts["skipped (too large)"] = counts.get("skipped (too large)", 0) + 1
                continue
            for f in s["files"]:
                rel = s["rel"] if h != "grok" else f"{s['rel']}/{Path(f).name}"
                dst = out / h / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, dst)          # keeps the original mtime
            counts[h] = counts.get(h, 0) + 1
    hs = [s for s in sessions if s["harness"] == "hermes"]
    if hs:
        counts["hermes"] = stage_hermes(hs, out)
    if convert:
        ps = [s for s in sessions if s["harness"] == "pi"]
        if ps:
            counts["pi (converted)"] = stage_pi(ps, out, pname)
        os_ = [s for s in sessions if s["harness"] == "opencode"]
        if os_:
            counts["opencode (converted)"] = stage_opencode(os_, out, pname)
    return counts


# ---------------------------------------------------------------- MCP check
def tls_context():
    """Verified TLS context. python.org builds on macOS ship without a CA bundle until their
    "Install Certificates" step runs; fall back to the system bundle or certifi, never to no checks."""
    ctx = ssl.create_default_context()
    if ctx.cert_store_stats().get("x509_ca"):
        return ctx
    for cafile in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
        if os.path.exists(cafile):
            return ssl.create_default_context(cafile=cafile)
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ctx


def mcp_check(url, token):
    sid = None
    def rpc(method, params=None, notify=False, n=[0]):
        nonlocal sid
        body = {"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}
        if not notify:
            n[0] += 1; body["id"] = n[0]
        h = {"content-type": "application/json", "accept": "application/json, text/event-stream",
             "authorization": f"Bearer {token}", "user-agent": "gbrain-project-setup/1.0"}
        if sid:
            h["mcp-session-id"] = sid
        req = urllib.request.Request(url, json.dumps(body).encode(), h, method="POST")
        with urllib.request.urlopen(req, timeout=30, context=tls_context()) as r:
            sid = r.headers.get("mcp-session-id") or sid
            raw = r.read().decode("utf-8", "replace")
            if "text/event-stream" in (r.headers.get("content-type") or ""):
                data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:") and l[5:].strip()]
                raw = data[-1] if data else "{}"
            return json.loads(raw) if raw.strip() else {}
    try:
        init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "gbrain-project-setup", "version": "1.0"}})
        rpc("notifications/initialized", notify=True)
        who = rpc("tools/call", {"name": "whoami", "arguments": {}})
        who = json.loads(who["result"]["content"][0]["text"])
        srch = rpc("tools/call", {"name": "search", "arguments": {"query": "project", "limit": 3}})
    except urllib.error.HTTPError as e:
        print(f"FAIL: HTTP {e.code} from {url} ({'bad/missing token' if e.code == 401 else e.reason})"); return 1
    except Exception as e:
        print(f"FAIL: cannot reach {url}: {e} (front door enabled? VPN up? SSH tunnel open?)"); return 1
    print(f"OK: {init['result']['serverInfo']['name']} {init['result']['serverInfo']['version']} at {url}")
    print(f"    token: {who.get('token_name')}  scopes: {','.join(who.get('scopes') or [])}")
    print(f"    search works: {'yes' if not srch.get('result', {}).get('isError') else 'NO'}")
    return 0


# ---------------------------------------------------------------- selection shared by scan / stage / sync
SELECT_DEFAULTS = dict(project=None, harness="all", since=None, until=None, exclude=[], skip_automated=False,
                       hermes_job=[], hermes_thread=[], hermes_session=[], grep=[], last=None,
                       skip_silent=False, convert_unsupported=False, changed_since=None)


def collect(a, quiet=False):
    """-> (project, harnesses, explicit_hermes, sessions) for an argparse namespace or sync entry."""
    project = norm(a.project or os.getcwd())
    explicit = bool(a.hermes_job or a.hermes_thread or a.hermes_session)
    hs = ALL if a.harness == "all" else [h.strip() for h in a.harness.split(",") if h.strip()]
    if explicit and a.harness == "all":
        hs = ["hermes"]
        if not quiet:
            print("note: Hermes selectors given, so only those are staged; stage the project's other"
                  " sessions with a separate command (or pass --harness)", file=sys.stderr)
    bad = [h for h in hs if h not in SCANNERS]
    if bad:
        raise ValueError(f"unknown harness: {bad}")
    cs = a.changed_since
    others = [h for h in hs if h != "hermes"]
    sessions = discover(project, others, a.since, set(a.exclude), a.skip_automated, cs)
    ue = epoch(a.until) + (86400 if len(a.until) == 10 else 0) if a.until else None
    sessions = [x for x in sessions if not (ue and (epoch(x.get("started")) or 0) >= ue)]
    if "hermes" in hs:
        if explicit:
            hrecs, problems = select_hermes(a.hermes_job, a.hermes_thread, a.hermes_session)
            if not quiet:
                for msg in problems:
                    print("note:", msg, file=sys.stderr)
                print("note: explicit Hermes selection is not limited to the project directory", file=sys.stderr)
        else:
            hrecs = scan_hermes(project, a.since)
        hrecs = [r for r in hrecs if r["id"] not in set(a.exclude)]
        # A job picked by name is a cron job: --skip-automated only narrows the project scan.
        skip_auto = a.skip_automated and not explicit
        sessions += hermes_filter(hrecs, a.since, a.until, a.grep, a.last, a.skip_silent, skip_auto, cs)
    return project, hs, explicit, sessions


# ---------------------------------------------------------------- hourly sync
CONF_DIR = Path(os.environ.get("GBRAIN_CONF_DIR", HOME / ".config" / "gbrain"))
SYNC_CONF = CONF_DIR / "sync.json"
SYNC_STATE = CONF_DIR / "sync-state.json"
OVERLAP = 900          # re-check the last 15 min each run: files still being written, clock skew


def load_json(p, default):
    try:
        return json.loads(Path(p).read_text())
    except Exception:
        return default


def save_json(p, data):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
    os.chmod(tmp, 0o600)
    tmp.replace(p)


def rsync_cmd(out, dest, dry=False, batch=False):
    rsync = "/opt/homebrew/bin/rsync" if Path("/opt/homebrew/bin/rsync").exists() else "rsync"
    cmd = [rsync, "-a", "--exclude", ".*"]
    if batch:   # never hang on a password/passphrase/host-key prompt in a scheduled run
        cmd += ["-e", "ssh -o BatchMode=yes -o ConnectTimeout=20"]
    return cmd + (["-n", "-v"] if dry else []) + [f"{out}/", dest.rstrip("/") + "/"]


def sync_add(a):
    conf = load_json(SYNC_CONF, {"entries": []})
    entry = {k: getattr(a, k) for k in SELECT_DEFAULTS if k != "changed_since" and getattr(a, k, None) not in (None, [], False)}
    if not (entry.get("project") or entry.get("hermes_job") or entry.get("hermes_thread") or entry.get("hermes_session")):
        print("sync add needs --project and/or --hermes-job/--hermes-thread/--hermes-session"); return 2
    if entry.get("project"):
        entry["project"] = norm(entry["project"])
    entry.update(name=a.name, dest=a.dest, start=time.time() - (a.backfill_hours or 0) * 3600)
    conf["entries"] = [e for e in conf["entries"] if e["name"] != a.name] + [entry]
    save_json(SYNC_CONF, conf)
    print(f"saved sync entry '{a.name}' -> {a.dest} in {SYNC_CONF}")
    print("  sends sessions with activity after " + iso(entry["start"]) + " UTC on the next run")
    return 0


def sync_run(a):
    import fcntl, tempfile
    conf = load_json(SYNC_CONF, {"entries": []})
    if not conf["entries"]:
        print(f"no sync entries in {SYNC_CONF} (use: sync add)"); return 0
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(CONF_DIR / "sync.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"{iso(time.time())} previous sync still running; skipping"); return 0
    state = load_json(SYNC_STATE, {})
    rc = 0
    for e in conf["entries"]:
        if a.only and e["name"] not in a.only:
            continue
        started = time.time()
        last = state.get(e["name"], {}).get("last_success", e.get("start", started - 7200))
        opts = argparse.Namespace(**{**SELECT_DEFAULTS, **{k: v for k, v in e.items() if k in SELECT_DEFAULTS}})
        opts.changed_since = last - OVERLAP
        try:
            project, hs, explicit, sessions = collect(opts, quiet=True)
        except Exception as ex:
            print(f"{iso(started)} [{e['name']}] ERROR selecting: {ex}"); rc = 1; continue
        if not sessions:
            print(f"{iso(started)} [{e['name']}] nothing changed since {iso(opts.changed_since)}")
            if not a.dry_run:
                state[e["name"]] = {"last_success": started, "last_count": 0}
            continue
        tmp = Path(tempfile.mkdtemp(prefix="gbrain-sync-"))
        try:
            counts = stage(sessions, tmp / "out", project, e.get("convert_unsupported", False))
            summary = ", ".join(f"{k}={v}" for k, v in counts.items())
            if not any((tmp / "out").rglob("*")):
                print(f"{iso(started)} [{e['name']}] nothing stageable ({summary})"); continue
            res = subprocess.run(rsync_cmd(tmp / "out", e["dest"], dry=a.dry_run, batch=True),
                                 capture_output=True, text=True)
            if res.returncode == 0:
                print(f"{iso(started)} [{e['name']}] {'would upload' if a.dry_run else 'uploaded'} {summary} -> {e['dest']}")
                if not a.dry_run:
                    state[e["name"]] = {"last_success": started, "last_count": len(sessions)}
            else:
                rc = 1
                print(f"{iso(started)} [{e['name']}] UPLOAD FAILED (rc={res.returncode}; will retry next run): "
                      f"{clip(res.stderr.strip(), 300)}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    if not a.dry_run:
        save_json(SYNC_STATE, state)
    return rc


# ---------------------------------------------------------------- scheduler (launchd / systemd --user / cron)
INSTALL_PATH = HOME / ".local" / "share" / "gbrain" / "gbrain_project.py"
LABEL = "com.gbrain.sync"


def schedule(a):
    every = max(300, int(a.every))
    py = sys.executable or "/usr/bin/python3"
    argv = [py, str(INSTALL_PATH), "sync", "run"]
    if sys.platform == "darwin":
        log = HOME / "Library" / "Logs" / "gbrain-sync.log"
        plist = HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
        body = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                '<plist version="1.0"><dict>\n'
                f'  <key>Label</key><string>{LABEL}</string>\n'
                '  <key>ProgramArguments</key><array>' + "".join(f"<string>{x}</string>" for x in argv) + '</array>\n'
                f'  <key>StartInterval</key><integer>{every}</integer>\n'
                f'  <key>StandardOutPath</key><string>{log}</string>\n'
                f'  <key>StandardErrorPath</key><string>{log}</string>\n'
                '  <key>ProcessType</key><string>Background</string>\n'
                '  <key>LowPriorityIO</key><true/>\n'
                '</dict></plist>\n')
        uid = os.getuid()
        if a.action == "install":
            if a.dry_run:
                print(f"# would write {plist}\n{body}"); return 0
            INSTALL_PATH.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(__file__, INSTALL_PATH); os.chmod(INSTALL_PATH, 0o700)
            plist.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
            plist.write_text(body)
            r = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", str(plist)], capture_output=True, text=True)
            print(f"installed {plist} (every {every}s, log {log})" if r.returncode == 0 else f"launchctl failed: {r.stderr}")
            return r.returncode
        if a.action == "remove":
            subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
            plist.unlink(missing_ok=True); print(f"removed {LABEL}"); return 0
        r = subprocess.run(["launchctl", "print", f"gui/{uid}/{LABEL}"], capture_output=True, text=True)
        print("loaded" if r.returncode == 0 else "not loaded", "| log:", log); return 0

    # Linux: systemd --user if available, else crontab
    has_user_systemd = shutil.which("systemctl") and subprocess.run(
        ["systemctl", "--user", "show-environment"], capture_output=True).returncode == 0
    if has_user_systemd:
        ud = HOME / ".config" / "systemd" / "user"
        svc = ("[Unit]\nDescription=gbrain transcript sync\n\n[Service]\nType=oneshot\n"
               f"ExecStart={' '.join(argv)}\nNice=10\n")
        tim = ("[Unit]\nDescription=gbrain transcript sync timer\n\n[Timer]\nOnBootSec=5min\n"
               f"OnUnitActiveSec={every}s\nRandomizedDelaySec=120\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n")
        if a.action == "install":
            if a.dry_run:
                print(f"# {ud}/gbrain-sync.service\n{svc}\n# {ud}/gbrain-sync.timer\n{tim}"); return 0
            INSTALL_PATH.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(__file__, INSTALL_PATH); os.chmod(INSTALL_PATH, 0o700)
            ud.mkdir(parents=True, exist_ok=True)
            (ud / "gbrain-sync.service").write_text(svc); (ud / "gbrain-sync.timer").write_text(tim)
            subprocess.run(["systemctl", "--user", "daemon-reload"])
            r = subprocess.run(["systemctl", "--user", "enable", "--now", "gbrain-sync.timer"])
            print("installed systemd user timer gbrain-sync.timer (logs: journalctl --user -u gbrain-sync)"); return r.returncode
        if a.action == "remove":
            subprocess.run(["systemctl", "--user", "disable", "--now", "gbrain-sync.timer"])
            for f in ("gbrain-sync.service", "gbrain-sync.timer"):
                (ud / f).unlink(missing_ok=True)
            subprocess.run(["systemctl", "--user", "daemon-reload"]); print("removed gbrain-sync.timer"); return 0
        return subprocess.call(["systemctl", "--user", "list-timers", "gbrain-sync.timer", "--no-pager"])
    log = HOME / ".local" / "state" / "gbrain" / "sync.log"
    line = f"{(os.getpid() % 50) + 5} * * * * {' '.join(argv)} >> {log} 2>&1  # gbrain-sync"
    cur = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    kept = "".join(l + "\n" for l in cur.splitlines() if "# gbrain-sync" not in l)
    if a.action == "install":
        if a.dry_run:
            print(line); return 0
        INSTALL_PATH.parent.mkdir(parents=True, exist_ok=True); log.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(__file__, INSTALL_PATH); os.chmod(INSTALL_PATH, 0o700)
        subprocess.run(["crontab", "-"], input=kept + line + "\n", text=True)
        print(f"installed hourly crontab entry (log {log})"); return 0
    if a.action == "remove":
        subprocess.run(["crontab", "-"], input=kept, text=True); print("removed crontab entry"); return 0
    print("installed" if "# gbrain-sync" in cur else "not installed"); return 0


# ---------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.add_argument("--url", required=True); c.add_argument("--token-env", default="GBRAIN_TOKEN")
    def selection_args(p, project_default):
        p.add_argument("--project", default=project_default)
        p.add_argument("--harness", default="all", help="comma list or 'all': " + ",".join(ALL))
        p.add_argument("--since", help="only sessions started on/after YYYY-MM-DD")
        p.add_argument("--exclude", nargs="*", default=[], help="session ids to leave out")
        p.add_argument("--skip-automated", action="store_true", help="leave out scheduled/cron runs (Hermes source=cron)")
        p.add_argument("--until", help="only sessions started on/before YYYY-MM-DD")
        hg = p.add_argument_group("explicit Hermes selection (not limited to --project; implies --harness hermes)")
        hg.add_argument("--hermes-job", action="append", default=[], metavar="NAME", help="cron job name, glob ok (repeatable)")
        hg.add_argument("--hermes-thread", action="append", default=[], metavar="ID",
                        help="session id (whole continuation chain) or chat_id/thread_id (repeatable)")
        hg.add_argument("--hermes-session", action="append", default=[], metavar="ID", help="session id or unique prefix (repeatable)")
        hg.add_argument("--grep", action="append", default=[], metavar="TEXT",
                        help="keep cron runs / project sessions mentioning TEXT (OR, repeatable); picked threads/sessions come whole")
        hg.add_argument("--last", type=int, metavar="N", help="keep the N most recent runs per cron job")
        hg.add_argument("--skip-silent", action="store_true", help="drop cron runs that answered [SILENT]")

    for name in ("scan", "stage"):
        p = sub.add_parser(name)
        selection_args(p, os.getcwd())
        p.add_argument("--changed-since", type=lambda v: epoch(v), help="only sessions with activity after ISO time")
        if name == "scan":
            p.add_argument("--json", action="store_true")
        else:
            p.add_argument("--out", required=True)
            p.add_argument("--convert-unsupported", action="store_true", help="also convert pi/opencode sessions")
    sy = sub.add_parser("sync", help="hourly sync: add/list/remove entries, or run once")
    ssub = sy.add_subparsers(dest="sync_cmd", required=True)
    sa = ssub.add_parser("add"); sa.add_argument("--name", required=True); sa.add_argument("--dest", required=True)
    sa.add_argument("--backfill-hours", type=float, default=0, help="also send the last N hours on the first run")
    sa.add_argument("--convert-unsupported", action="store_true")
    selection_args(sa, None)
    ssub.add_parser("list")
    sr = ssub.add_parser("remove"); sr.add_argument("--name", required=True)
    sn = ssub.add_parser("run"); sn.add_argument("--dry-run", action="store_true"); sn.add_argument("--only", nargs="*")
    sc = sub.add_parser("schedule", help="install/remove/status of the hourly job (launchd, systemd --user, cron)")
    sc.add_argument("action", choices=["install", "remove", "status"])
    sc.add_argument("--every", default=3600, help="seconds between runs (default 3600)")
    sc.add_argument("--dry-run", action="store_true")
    hl = sub.add_parser("hermes", help="list Hermes cron jobs, runs of a job, or conversation threads")
    hl.add_argument("what", choices=["jobs", "runs", "threads"])
    hl.add_argument("--job", help="runs: cron job name (glob ok)")
    hl.add_argument("--project", default=os.getcwd()); hl.add_argument("--all", action="store_true", help="threads: every directory")
    hl.add_argument("--since"); hl.add_argument("--until"); hl.add_argument("--grep", action="append", default=[])
    hl.add_argument("--last", type=int); hl.add_argument("--skip-silent", action="store_true")
    u = sub.add_parser("upload"); u.add_argument("--out", required=True); u.add_argument("--dest", required=True)
    u.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.cmd == "check":
        tok = os.environ.get(a.token_env, "").strip()
        if not tok:
            print(f"FAIL: ${a.token_env} is empty (export it from ~/.config/gbrain/token)"); return 1
        return mcp_check(a.url, tok)

    if a.cmd == "sync":
        if a.sync_cmd == "add":
            return sync_add(a)
        if a.sync_cmd == "list":
            conf, state = load_json(SYNC_CONF, {"entries": []}), load_json(SYNC_STATE, {})
            for e in conf["entries"]:
                st = state.get(e["name"], {})
                what = {k: v for k, v in e.items() if k not in ("name", "dest", "start")}
                print(f"{e['name']}: -> {e['dest']}  last ok: {iso(st.get('last_success')) or 'never'}  {json.dumps(what)}")
            if not conf["entries"]:
                print(f"no entries in {SYNC_CONF}")
            return 0
        if a.sync_cmd == "remove":
            conf = load_json(SYNC_CONF, {"entries": []})
            conf["entries"] = [e for e in conf["entries"] if e["name"] != a.name]
            save_json(SYNC_CONF, conf); print(f"removed '{a.name}'"); return 0
        return sync_run(a)

    if a.cmd == "schedule":
        return schedule(a)

    if a.cmd == "hermes":
        if a.what == "runs" and not a.job:
            print("hermes runs needs --job NAME (see: hermes jobs)"); return 2
        return hermes_list(a.what, a)

    if a.cmd in ("scan", "stage"):
        try:
            project, hs, explicit, sessions = collect(a)
        except ValueError as e:
            print(e); return 2
        if a.cmd == "scan":
            if a.json:
                print(json.dumps([{k: v for k, v in s.items() if k not in ("files", "last")} for s in sessions], indent=1, default=str))
                return 0
            print(f"project: {project}" + ("  (Hermes: explicit selection)" if explicit else ""))
            if not sessions:
                print("no sessions found for this project in: " + ", ".join(hs)); return 0
            cur = None
            for s in sessions:
                if s["harness"] != cur:
                    cur = s["harness"]
                    grp = [x for x in sessions if x["harness"] == cur]
                    note = "  (no gbrain adapter: needs --convert-unsupported)" if cur in CONVERTED else ""
                    auto = sum(1 for x in grp if x.get("automated"))
                    if auto:
                        note += f"  ({auto} automated/cron runs; --skip-automated leaves them out)"
                    print(f"\n{cur}: {len(grp)} session(s){note}")
                size = f"{s['bytes'] / 1024:.0f} KB" if s.get("bytes") else ""
                flag = "  [TOO LARGE: >50 MB, will be skipped]" if too_big(s) else ""
                if s.get("silent"):
                    flag += "  [SILENT]"
                print(f"  {iso(s.get('started')):16}  {s['id'][:36]:36}  {size:>8}  {clip(s.get('title'))}{flag}")
            return 0
        out = Path(a.out).expanduser()
        counts = stage(sessions, out, project, a.convert_unsupported)
        skipped = [] if a.convert_unsupported else sorted({s["harness"] for s in sessions if s["harness"] in CONVERTED})
        print(f"staged into {out}: " + (", ".join(f"{k}={v}" for k, v in counts.items()) or "nothing"))
        if skipped:
            print(f"not staged (no adapter; rerun with --convert-unsupported): {', '.join(skipped)}")
        return 0

    if a.cmd == "upload":
        out = Path(a.out).expanduser()
        if not out.is_dir() or not any(out.iterdir()):
            print(f"nothing to upload in {out}"); return 1
        cmd = rsync_cmd(out, a.dest, dry=a.dry_run)
        print("running:", " ".join(cmd), flush=True)
        return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main() or 0)
```
<!-- END gbrain_project.py -->
