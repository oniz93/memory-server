# Server guide

For the person who runs the server (the **brain owner**). Everything below runs on the server.
`$ROOT` is `GBRAIN_ROOT` (default `/srv/gbrain`), `$DATA` is `GBRAIN_DATA_DIR`.

## 1. Configuration

All settings live in `/etc/gbrain/gbrain.conf` ([example](../deploy/gbrain.conf.example)): plain
`KEY=VALUE`, read by the scripts, by systemd and by the installer.

| Setting | Meaning |
|---|---|
| `GBRAIN_USER` | Unix user that owns the install and runs the services. Needs docker access (backups). |
| `GBRAIN_ROOT` | Small files: scripts, config, secrets, the inbox mountpoint. |
| **`GBRAIN_DATA_DIR`** | **Everything that grows**: `pg/` (Postgres), `backups/`, `logs/`, `inbox.img` (the upload inbox). Put it on your big disk. |
| `GBRAIN_BUN_BIN` | Directory holding the user's `bun` and `gbrain` executables. |
| `GBRAIN_REF` | Git ref of GBrain to install (`stable` moves; pin a commit for reproducibility). |
| `GBRAIN_HTTP_PORT`, `GBRAIN_PG_PORT`, `GBRAIN_SHIM_PORT` | Loopback ports. |
| `GBRAIN_TUNNEL_PORT` | Port of the VPN front doors (on the VPN address only). |
| `GBRAIN_INBOX_SIZE`, `GBRAIN_DONE_KEEP_DAYS`, `GBRAIN_DONE_MAX_MB` | Size cap of the upload inbox and retention of processed uploads. |
| `GBRAIN_PG_MEM_MB`, `GBRAIN_SERVE_MEM_MB` | Memory caps. |
| `GBRAIN_BACKUP_KEEP_DAILY`, `GBRAIN_BACKUP_KEEP_WEEKLY`, `GBRAIN_OFFSITE_RSYNC` | Backup retention and optional offsite copy. |

After editing the file, run `sudo deploy/install.sh` again: it re-renders the units and restarts
only what changed.

### The data directory

The services declare `RequiresMountsFor=$DATA`, and the Postgres container is configured never to
create its data directory. If the data disk is not mounted, nothing starts, and no empty
database is ever initialised on the wrong disk. The installer also refuses to recreate `$DATA/pg`
on an existing install.

**Never move data by editing the path.** Use the mover:

```bash
sudo $ROOT/bin/move-data.sh /mnt/bigdisk/gbrain
```

It checks free space, takes a fresh backup, records row counts, stops the services, copies
`pg/ backups/ logs/ inbox.img` with rsync, switches the config, re-runs the installer, starts
everything from the new place and compares the row counts. If anything fails before the switch,
it restarts from the old location with the config untouched. The old copy is renamed
`*.moved-<date>` and kept until you delete it.

## 2. Install and update

```bash
sudo deploy/install.sh                  # install or update (idempotent)
sudo deploy/install.sh --with-fail2ban  # also install fail2ban with the gbrain jail
sudo deploy/install.sh --no-start       # files and units only
deploy/install.sh --render-only /tmp/x  # render every template for inspection; changes nothing
```

What it sets up:

| Piece | Where |
|---|---|
| Postgres 17 + pgvector | container `gbrain-pg`, `127.0.0.1:$GBRAIN_PG_PORT`, data in `$DATA/pg`, managed by `gbrain-pg.service` |
| GBrain MCP server | `gbrain.service`, `127.0.0.1:$GBRAIN_HTTP_PORT`, keyword-only, auto-saving off |
| Upload inbox | loop image `$DATA/inbox.img` mounted at `$ROOT/inbox` (`nodev,nosuid,noexec`) |
| Ingest | `gbrain-ingest.timer`, every 15 minutes |
| Backups | `gbrain-backup.timer`, nightly, into `$DATA/backups` |
| Logs | `$DATA/logs`, rotated by `/etc/logrotate.d/gbrain` |
| Secrets | `$ROOT/secrets` (0700): database password, admin bootstrap token, tokens you mint |

Both services that touch uploaded data run sandboxed: no privilege escalation, no docker or
containerd socket, no `~/.ssh`, read-only home, writes only to their own directories. Check with
`sudo bash tests/test_unit_sandbox.sh /etc/systemd/system/gbrain-ingest.service $ROOT/inbox`.

**Upgrade GBrain:** set `GBRAIN_REF` if you pin, then as `GBRAIN_USER`:

```bash
bun install -g github:garrytan/gbrain#<ref>
gbrain apply-migrations --yes --no-autopilot-install
sudo systemctl restart gbrain && gbrain doctor
```

Bun blocks GBrain's postinstall script; that is harmless, because `apply-migrations` does the
same work. Never `npm install -g gbrain`: that is an unrelated package.

## 3. Sources and tokens

A **source** is a named compartment of the brain. A **token** is granted a list of sources; it
reads all of them and **writes only to the first**. As `GBRAIN_USER`, with
`export GBRAIN_HOME=$ROOT/home PATH=$GBRAIN_BUN_BIN:$PATH`:

```bash
# sources: one per shared project, plus a private one for the owner
mkdir -p $ROOT/sources/research-alpha $ROOT/sources/owner-private
gbrain sources add research-alpha --path $ROOT/sources/research-alpha --name "Research: Alpha" --federated --force
gbrain sources add owner-private  --path $ROOT/sources/owner-private  --name "Owner (private)" --no-federated --force

# one token per person (the secret is printed once: store it, hand it over out-of-band)
gbrain auth create alice --scopes read,write
gbrain auth rescope --token alice --sources research-alpha --private-pages none

# the owner: one token per write target
gbrain auth create owner --scopes read,write
gbrain auth rescope --token owner --sources research-alpha
gbrain auth create owner-private --scopes read,write
gbrain auth rescope --token owner-private --sources owner-private,research-alpha --private-pages granted-sources

gbrain auth list                       # ids, scopes, last used
gbrain auth rescope --token alice      # print a grant
gbrain auth revoke alice               # offboard or rotate
```

Rule worth keeping: **no credential should read a private source and write a shared one.**
Otherwise shared content could instruct an agent to copy private pages into the shared source.
The private token above writes only to the private source.

Check any token end to end with the bundled client:

```bash
$ROOT/bin/mcp-call.py --token-file $ROOT/secrets/tokens/alice.token tools
$ROOT/bin/mcp-call.py --token-file $ROOT/secrets/tokens/alice.token call search '{"query":"something"}'
```

## 4. Uploads

`$ROOT/etc/inbox-policy.conf` lists which sources each person may upload into
([example](../deploy/inbox-policy.conf.example)). Keep it in line with the token grants.

Each person, the owner included, creates a dedicated upload key on their machine (the agent
guide does this) and sends you the public half. Register it as `GBRAIN_USER`:

```bash
$ROOT/bin/inbox-key.sh add alice /tmp/alice-gbrain_upload.pub
$ROOT/bin/inbox-key.sh list
$ROOT/bin/inbox-key.sh remove alice
```

That key can only run `rrsync -munge -no-del -wo` on `inbox/alice`: write-only, no reads, no
deletes, no shell, no forwarding, symlinks neutralised. It lives in `GBRAIN_USER`'s
`authorized_keys`, so no new login account is needed. If you prefer a separate account for
uploads, create one, allow it in sshd, and run `inbox-key.sh` as that account with
`GBRAIN_INBOX` writable by it.

How uploads are processed is described in [ingestion.md](ingestion.md).

## 5. Front doors

Nothing is reachable from outside until you enable a door. All doors share one gate:

| Request | Result |
|---|---|
| `/mcp` without a bearer header | connection dropped |
| `/token`, `/revoke`, `/.well-known/oauth-*` | allowed, 6 requests/min per IP |
| `/admin` | VPN doors only (still needs the owner login) |
| anything else | connection dropped |

Failed attempts (401, 403, dropped) are counted by fail2ban: 5 in 10 minutes bans the address
for an hour, doubling up to a week. Rate-limit responses are not counted.

A client that starts without its token (an empty `Bearer`) is dropped like any stranger, and MCP
clients retry quickly, so a misconfigured harness bans its own person within seconds. The usual
culprit is a background service started before `GBRAIN_TOKEN` was exported (OpenCode 2.x). Fix the
client first, then lift the ban:

```bash
sudo fail2ban-client status gbrain-auth                  # who is banned
sudo fail2ban-client set gbrain-auth unbanip <address>   # their VPN address
```

```bash
sudo $ROOT/bin/enable-frontdoor.sh status
sudo $ROOT/bin/enable-frontdoor.sh tailscale            # http://<tailscale-ip>:$GBRAIN_TUNNEL_PORT/mcp
sudo $ROOT/bin/enable-frontdoor.sh wireguard 10.66.0.1  # the server's WireGuard address
sudo $ROOT/bin/enable-frontdoor.sh public brain.example.org   # after the DNS A record exists
sudo $ROOT/bin/enable-frontdoor.sh disable tailscale
```

The script validates with `nginx -t` and rolls back on failure, so a bad render never reaches the
running nginx. VPN doors are plain HTTP on the VPN address only: the tunnel encrypts and
authenticates the peer, and `/mcp` still needs a token. The public door needs nginx and certbot.

Only the public door changes the OAuth issuer (`GBRAIN_PUBLIC_URL`). gbrain refuses to start with an
issuer that is neither HTTPS nor loopback, so VPN doors keep the loopback default: bearer tokens
work there, OAuth client logins need the public door. The script restarts gbrain after an issuer
change and puts the old value back if it does not come up.

Owner dashboard: `/admin` through a VPN door, or `ssh -L 3131:127.0.0.1:3131 <server>`. Get a
one-time login link (the header travels on stdin, so the token never shows in a process list):

```bash
sed -n 's/^GBRAIN_ADMIN_BOOTSTRAP_TOKEN=/Authorization: Bearer /p' $ROOT/secrets/serve.env |
  curl -s -X POST -H @- http://127.0.0.1:3131/admin/api/issue-magic-link
```

## 6. Handing out the agent guide

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}'      # your host-key fingerprint
python3 scripts/build_agent_setup.py --person alice \
    --url http://<door-address>:3132/mcp --source research-alpha \
    --ssh <GBRAIN_USER>@<server-address> --hostkey SHA256:<fingerprint>
```

That writes `out/AGENT_SETUP-alice.md` (git-ignored). Send it with the token, separately.

## 7. Optional LLM lane

Default: keyword search only, nothing leaves the server. To let GBrain use an LLM for
`synthesize` / `think`, query expansion and `transcripts ingest --facts` through OpenCode Go:

```bash
umask 077; echo 'OPENCODE_GO_API_KEY=<key>' > $ROOT/secrets/llm.env
$ROOT/bin/gbrain-llm.sh on glm-5.3      # any OpenCode Go chat model id
$ROOT/bin/gbrain-llm.sh test
$ROOT/bin/gbrain-llm.sh off             # back to keyword-only
```

- OpenCode Go has no embeddings endpoint, so search stays keyword in both modes.
- A loopback shim adds the session header and user agent that Go requires, caps requests per day
  (`DAILY_REQUEST_CAP` in `llm.env`, default 500) and logs metadata only.
- Source isolation holds here too: a person's `synthesize` only sends text from sources their
  token can read.
- **This sends page and transcript text to a third party.** Check the provider's terms for
  non-interactive use, and tell your collaborators.

## 8. Backups, health, logs

```bash
sudo systemctl start gbrain-backup.service        # run now; nightly otherwise
$ROOT/bin/gbrain-health.sh                        # exit 1 and a list when something is wrong
```

- Backups: `pg_dump` custom format plus a config tarball in `$DATA/backups/daily` (and `weekly`
  on Sundays). Every dump is verified with `pg_restore -l`. **Secrets are not in the backup**:
  keep `$ROOT/secrets` in a password manager.
- Offsite: set `GBRAIN_OFFSITE_RSYNC=user@host:/path/`. A failed offsite copy fails the unit and
  shows up in the health check.
- Restore:
  ```bash
  sudo systemctl stop gbrain gbrain-ingest.timer
  docker exec -i gbrain-pg pg_restore -U gbrain -d gbrain --clean --if-exists < $DATA/backups/daily/gbrain-YYYY-MM-DD.dump
  sudo systemctl start gbrain gbrain-ingest.timer
  ```
- Health check covers: data disk, Postgres, the MCP server, memory near the caps, backup age,
  failed uploads, inbox capacity. `--porcelain` prints `key<TAB>level<TAB>message` for scripts;
  [`deploy/contrib/gbrain-monitor.sh`](../deploy/contrib/gbrain-monitor.sh) hooks it into an
  existing bash monitor.

## 9. Removing everything

```bash
sudo $ROOT/bin/enable-frontdoor.sh status          # disable any enabled door first
sudo systemctl disable --now gbrain gbrain-pg gbrain-ingest.timer gbrain-backup.timer gbrain-llm-shim
sudo systemctl disable --now "$(systemd-escape -p --suffix=mount $ROOT/inbox)"
docker compose -f $ROOT/compose.yml --env-file $ROOT/secrets/db.env down
sudo rm /etc/systemd/system/gbrain*.service /etc/systemd/system/gbrain*.timer /etc/logrotate.d/gbrain
sudo rm -f /etc/fail2ban/jail.d/gbrain.local /etc/fail2ban/filter.d/gbrain-auth.conf
sudo systemctl daemon-reload
# data and config last, once you are sure:  $DATA, $ROOT (chattr -i $ROOT/inbox first), /etc/gbrain
```
