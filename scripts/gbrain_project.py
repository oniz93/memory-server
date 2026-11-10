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
