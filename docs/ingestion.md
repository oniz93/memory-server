# Transcript ingestion

How past and ongoing sessions get from people's machines into the brain. The agent guide
([AGENT_SETUP.md](../AGENT_SETUP.md)) drives all of this; this page explains what happens.

## On each machine: `gbrain_project.py`

A stdlib-only helper (embedded in the guide, also in [`scripts/`](../scripts/gbrain_project.py)).

```bash
H=scripts/gbrain_project.py
python3 $H check  --url <mcp-url>                 # handshake + whoami + a search, token from $GBRAIN_TOKEN
python3 $H scan   --project .                     # read-only: this project's sessions, per harness
python3 $H stage  --project . --out /tmp/stage    # copy / convert into <harness>/… (0700)
python3 $H upload --out /tmp/stage --dest gbrain-upload:research-alpha [--dry-run]
```

A session belongs to a project when its working directory is the project directory or below it.

| Harness | Where sessions live | How they are sent |
|---|---|---|
| Claude Code | `~/.claude/projects/<slug>/*.jsonl` | as is |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | as is |
| Grok Build | `~/.grok/sessions/<cwd>/<uuid>/chat_history.jsonl` (+ `summary.json`) | as is |
| Hermes | `~/.hermes/state.db` (+ profiles) | a small SQLite slice with only the chosen sessions |
| Pi | `~/.pi/agent/sessions/<cwd>/*.jsonl` | converted (`--convert-unsupported`) |
| OpenCode | `~/.local/share/opencode/opencode.db` | converted (`--convert-unsupported`) |

Pi and OpenCode have no GBrain importer. The helper converts their user and assistant text into
the same slice layout as Hermes, with the session's `source` set to `pi` or `opencode` and the id
prefixed, so the origin stays visible.

Limits handled for you: sessions over GBrain's 50 MB per-file limit are flagged and skipped;
scheduled (cron) runs are counted separately so they can be left out (`--skip-automated`).

### Hermes cron jobs, threads and single sessions

Scheduled jobs often run in a different directory from the project, so they are selected
explicitly rather than by directory:

```bash
python3 $H hermes jobs                                    # every job: runs, runs with text, [SILENT] runs, dates, cwd
python3 $H hermes runs --job nightly-report --since 2026-01-01 --grep "regression" --last 20 --skip-silent
python3 $H hermes threads [--all]                         # conversations with their continuations, and chat ids
python3 $H stage --out /tmp/stage --hermes-job 'nightly-*' --grep regression \
                 --hermes-thread <root id | any session in it | chat_id> --hermes-session <id or 8+ char prefix>
```

- A cron run is tied to its job by its title (`<job> · <date>`), or by the job id inside older
  session ids. Hermes keeps no durable job-to-session link.
- `--since`, `--until`, `--grep`, `--last N` (per job) and `--skip-silent` narrow cron runs.
  A picked thread or session always comes whole.
- Each job or thread becomes its own slice, named after the exact set of sessions in it. That
  matters because the server remembers "what I already imported" per file name: a different
  selection never reuses a name, and re-sending the same selection is free.

### Hourly sync

```bash
python3 $H sync add --name myproject --dest gbrain-upload:research-alpha --project .
python3 $H sync add --name nightly   --dest gbrain-upload:research-alpha --hermes-job nightly-report --skip-silent
python3 $H sync run [--dry-run]
python3 $H schedule install          # launchd (macOS), systemd user timer, or cron; `schedule remove` undoes it
```

Each run sends only sessions with new activity since the entry's last **successful** run, minus a
15-minute overlap. A failed upload leaves the marker where it was, so the next run catches up.
Entries live in `~/.config/gbrain/sync.json`; the scheduled job runs a copy of the helper
installed in `~/.local/share/gbrain/`. Scheduled uploads cannot answer prompts, so they use a
dedicated key without a passphrase, which the server restricts to write-only uploads.

## On the server: the inbox

```
$ROOT/inbox/<person>/<source-id>/<harness>/…      harness: hermes | claude-code | codex | grok | openclaw | chatgpt | claude-export
$ROOT/inbox/.done/<date>/…        ingested (kept GBRAIN_DONE_KEEP_DAYS days, capped at GBRAIN_DONE_MAX_MB)
$ROOT/inbox/.failed/<date>/…      failed three times (the health check reports it)
$ROOT/inbox/.rejected/<date>/…    not allowed by the policy, no source directory, or suspicious
```

`ingest_inbox.sh` runs every 15 minutes:

1. Takes a file once it has been unchanged for 2 minutes and is not a dotfile (rsync's temporary
   names), so partial uploads are never read.
2. Checks `<person>` and `<source-id>` against `etc/inbox-policy.conf`. Anything else goes to
   `.rejected`.
3. Treats the upload as hostile: NUL-safe paths, control characters rejected, symlinks never
   followed, every path resolved and required to stay inside `<person>/<source>/`.
4. Runs one `gbrain transcripts ingest … --source-id <source> --since last` per person, source
   and format. The format comes from the `<harness>` directory, else the file name, else GBrain
   detects it.
5. Reads GBrain's per-file result: imported files move to `.done`; files still publishing stay
   for the next run; failures are retried and move to `.failed` after three attempts.

Run it by hand with `sudo systemctl start gbrain-ingest.service`, or without changing anything:
`DRY_RUN=1 GBRAIN_SETTLE_SECS=0 $ROOT/bin/ingest_inbox.sh`. Results are logged per batch in
`$DATA/logs/ingest.jsonl`.

## Checking an import

```bash
gbrain transcripts status                              # found vs imported, per harness
gbrain transcripts audit-secrets                       # pages that may still carry a credential (slugs only)
gbrain search "<a phrase from that session>" --source <source-id>
```

## Other content

- `gbrain import <dir> --source <id> --no-embed` indexes a Markdown tree: curated notes or a
  written summary you want shared without sharing the chat log.
- ChatGPT and Claude.ai account exports (`conversations.json`) are whole-account imports. Only
  do that deliberately, into a source you are willing to share.
