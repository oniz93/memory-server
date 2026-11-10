#!/usr/bin/env python3
"""build_agent_setup.py — embed scripts/gbrain_project.py into AGENT_SETUP.md, optionally per person.

  python3 scripts/build_agent_setup.py                    # refresh the embedded helper in place
  python3 scripts/build_agent_setup.py --person alice \\
      --url http://100.x.y.z:3132/mcp --source research-alpha \\
      --ssh gbrain@brain.example.org --hostkey SHA256:...   # -> out/AGENT_SETUP-alice.md

  --url      the MCP endpoint of the enabled front door (enable-frontdoor.sh prints it)
  --source   the source this person's token writes to
  --ssh      SSH user@host of the server's upload inbox (the GBRAIN_USER account)
  --hostkey  the server's ED25519 host-key fingerprint:
             ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}'

The in-repo AGENT_SETUP.md keeps the {{...}} placeholders; personalised copies go to out/ (which
is git-ignored: they contain your server's address). Tokens are never part of the guide.
"""
import argparse, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE = ROOT / "AGENT_SETUP.md"
HELPER = ROOT / "scripts" / "gbrain_project.py"
BEGIN = "<!-- BEGIN gbrain_project.py"
END = "<!-- END gbrain_project.py -->"


def embed(text: str) -> str:
    code = HELPER.read_text()
    if "```" in code:
        sys.exit("helper contains a code fence and cannot be embedded")
    b = text.index(BEGIN)
    b_end = text.index("-->", b) + 3
    e = text.index(END)
    return text[:b_end] + "\n```python\n" + code.rstrip("\n") + "\n```\n" + text[e:]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for flag in ("--person", "--url", "--source", "--ssh", "--hostkey"):
        ap.add_argument(flag)
    a = ap.parse_args()
    text = embed(GUIDE.read_text())
    GUIDE.write_text(text)
    print(f"embedded {HELPER.name} into {GUIDE.name}")
    if not a.person:
        return
    missing = [f for f in ("url", "source", "ssh", "hostkey") if not getattr(a, f)]
    if missing:
        sys.exit("missing: " + ", ".join("--" + m for m in missing))
    if "@" not in a.ssh:
        sys.exit("--ssh must be user@host")
    if not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", a.hostkey):
        sys.exit("--hostkey must look like SHA256:<43 characters>")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}", a.person) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}", a.source):
        sys.exit("--person and --source must be lowercase names (a-z, 0-9, _ and -)")
    user, host = a.ssh.split("@", 1)
    vals = {"PERSON": a.person, "GBRAIN_MCP_URL": a.url, "GBRAIN_SOURCE": a.source,
            "GBRAIN_SSH_USER": user, "GBRAIN_SSH_HOST": host, "GBRAIN_HOSTKEY": a.hostkey}
    personal = text
    for k, v in vals.items():
        personal = personal.replace("{{" + k + "}}", v)
    left = re.findall(r"\{\{[A-Z_]+\}\}", personal)
    if left:
        sys.exit(f"unfilled placeholders: {sorted(set(left))}")
    out = ROOT / "out" / f"AGENT_SETUP-{a.person}.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text(personal)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
