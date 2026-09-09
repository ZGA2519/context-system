#!/usr/bin/env python3
"""Install the context system into a repo: store, MCP entry, skill, commands, hook.

The Python twin of install.sh, for machines without a POSIX sh and for running as a
tool: `uv run context-system` in a checkout, or without one
`uvx --from git+https://github.com/ZGA2519/context-system context-system`.
Idempotent, re-run to update an install. An existing .context/memories/ is never touched.
Run with no answers on a terminal and it asks for them; -y takes the defaults.
"""
import argparse
import atexit
import importlib.metadata
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

REPO_URL = "https://github.com/ZGA2519/context-system.git"
CLIENT_FLAGS = ["--claude", "--codex", "--gemini", "--agy", "--vscode"]
MCP_ENTRY = {"command": "uv", "args": ["run", "--directory", ".context", "python", "-m", "context_store.server", "mcp"]}
HOOK_CMD = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/context-sync.sh'

USAGE = """\
%(prog)s [TARGET_REPO] [-y] [--no-hook] [--claude] [--codex] [--gemini] [--agy] [--vscode]
       %(prog)s [FOLDER] --set-root [-y]"""
DESCRIPTION = """\
Installs into TARGET_REPO (default: the current directory):

  .context/                             the store and MCP server
  .mcp.json                             mcpServers.context-system, merged in
  .claude/skills/context-sync/          the skill
  .claude/commands/context-*.md         /context-start-sync, -readonly, /context-stop-sync
  .claude/hooks/context-sync.sh         per-prompt loop re-injection
  .claude/settings.json                 the UserPromptSubmit hook, merged in
  .agent/skills/context-sync/           the same skill, vendor-neutral tree
  .agent/prompts/context-*.md           the same commands, called prompts there

  --no-hook   skip the last two; the skill alone drives the loop
  --claude --codex --gemini --agy --vscode
              also register the server with those clients, via .context/setup.sh

Anything not given is asked for interactively when there is a terminal. -y (--yes)
answers every question with its default instead: the current directory, the hook on,
no extra clients.

--set-root      the other job: FOLDER (default: the current directory) is a workspace
                folder opened over several repos. Finds every repo with a .context/
                install up to 5 levels below it, asks which should join, and runs each
                one's .context/setup.sh --set-root FOLDER. -y takes them all."""

if os.name == "nt":
    os.system("")  # ponytail: the documented hack that turns on ANSI escapes in conhost
sys.stdout.reconfigure(errors="replace")  # glyphs below must not crash a cp1252 pipe
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    B, D, R, C, G, Y, M = "\033[1m", "\033[2m", "\033[0m", "\033[36m", "\033[32m", "\033[33m", "\033[35m"
else:
    B = D = R = C = G = Y = M = ""

count = Counter()


def sec(title):
    print(f"\n{M}▌{R} {B}{title}{R}")


def say(path, status):
    """One row; glyph and colour follow the status verb, counted for the summary."""
    if "already" in status or status.startswith("kept"):
        glyph, colour, kind = f"{D}•", D, "same"
    elif status.startswith("skipped"):
        glyph, colour, kind = f"{Y}!", Y, "skip"
    else:
        verbs = ("added", "registered", "created", "replaced", "removed")
        glyph, colour, kind = f"{G}✔", G if any(v in status for v in verbs) else "", "new"
    count[kind] += 1
    print(f"  {glyph}{R} {C}{path:<28}{R} {colour}{status}{R}")


def load_json(p):
    if p.exists() and p.read_text().strip():
        try:
            return json.loads(p.read_text())
        except json.JSONDecodeError as e:
            sys.exit(f"{p} is not valid JSON ({e}); fix or move it and re-run")
    return {}


def save_json(p, doc):
    p.write_text(json.dumps(doc, indent=2) + "\n")


# --- prompts ---------------------------------------------------------------
# Plain line prompts, so they work in every terminal cmd.exe included. Only asked
# for what the flags left open. Ctrl-C or EOF anywhere cancels with nothing written.
def ask(prompt):
    try:
        return input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        print(f"\n  {Y}! cancelled, nothing written{R}")
        sys.exit(130)


def done(title, answer):
    print(f"{G}✔{R} {title} {D}›{R} {C}{answer}{R}")


def options(items):
    for i, (label, hint) in enumerate(items, 1):
        print(f"  {M}{i}{R} {label:<14} {D}{hint}{R}")


def ask_select(title, items, default=1):
    print(f"{M}?{R} {B}{title}{R}")
    options(items)
    while True:
        a = ask(f"  {D}number ({default}):{R} ") or str(default)
        if a.isdigit() and 1 <= int(a) <= len(items):
            done(title, items[int(a) - 1][0])
            return int(a)
        print(f"  {Y}! pick 1-{len(items)}{R}")


def ask_multi(title, items, default=()):
    print(f"{M}?{R} {B}{title}{R}")
    options(items)
    hint = "all" if len(default) == len(items) else "none"
    while True:
        raw = ask(f"  {D}numbers, space separated, or all ({hint}):{R} ")
        if raw.lower() == "all":
            raw = " ".join(str(i) for i in range(1, len(items) + 1))
        picks = raw.split() if raw else [str(p) for p in default]
        if all(p.isdigit() and 1 <= int(p) <= len(items) for p in picks):
            picks = sorted({int(p) for p in picks})
            done(title, ", ".join(items[p - 1][0] for p in picks) or "none")
            return picks
        print(f"  {Y}! pick from 1-{len(items)}{R}")


def ask_yesno(title, default=True):
    while True:
        a = ask(f"{M}?{R} {B}{title}{R} {D}({'Y/n' if default else 'y/N'}){R} ").lower()
        if a in ("", "y", "yes", "n", "no"):
            yes = default if a == "" else a[0] == "y"
            done(title, "yes" if yes else "no")
            return yes


def ask_path(src):
    """The target, asked until it is a real directory that is not the checkout."""
    default = "" if Path.cwd() == src else str(Path.cwd())
    while True:
        a = ask(f"{M}?{R} {B}install into which repo?{R} {D}{f'({default})' if default else ''}{R} ") or default
        p = Path(a).expanduser()
        if not a:
            why = "a path is needed"
        elif not p.is_dir():
            why = "no such directory"
        elif p.resolve() == src:
            why = "that is the context-system checkout; pass the repo to install into"
        else:
            done("install into which repo?", p.resolve())
            return p.resolve()
        print(f"  {Y}! {why}{R}")


def find_repos(root, depth=5):
    """Repos with an install (.context/setup.sh) up to `depth` directories below root."""
    found = []
    for d, dirs, _ in os.walk(root):
        d = Path(d)
        if d != root and ".context" in dirs and (d / ".context/setup.sh").is_file():
            found.append(d)
        deep = len(d.relative_to(root).parts) >= depth
        dirs[:] = [] if deep else sorted(n for n in dirs if not n.startswith(".") and n != "node_modules")
    return found


def set_root(root, yes):
    """Add every chosen repo below root to root's .mcp.json, via each repo's own setup.sh."""
    root = root.resolve()
    if not root.is_dir():
        sys.exit(f"install: no such directory: {root}")
    repos = find_repos(root)
    if not repos:
        sys.exit(f"install: no repo with a .context/ install within 5 levels below {root}")
    reg = root / ".claude/context-sync.repos"
    known = {line.split(" ", 1)[1] for line in reg.read_text().splitlines() if " " in line} if reg.is_file() else set()
    items = [(str(r.relative_to(root)), "already registered here" if str(r) in known else "") for r in repos]
    picks = list(range(1, len(items) + 1))
    if not yes and sys.stdin.isatty() and sys.stdout.isatty():
        print(f"\n{M}▌{R} {B}context-system{R} {D}workspace folder{R} {C}{root}{R}\n")
        picks = ask_multi("which repos should join this folder?", items, default=picks)
        if not picks:
            print(f"  {D}nothing picked, nothing done{R}")
            return
    for i in picks:  # ponytail: shells out to setup.sh; port its set_root here if Windows needs this
        try:
            subprocess.run(["sh", str(repos[i - 1] / ".context/setup.sh"), "--set-root", str(root)])
        except OSError:
            sys.exit(f"install: no sh on PATH; run {repos[i - 1]}/.context/setup.sh --set-root {root} from a shell that has one")


def release_ref():
    """--branch v<version> when installed from PyPI, so 0.1.1 installs the 0.1.1 tree.
    Nothing (main) when installed from a git URL or path: direct_url.json marks those."""
    try:
        dist = importlib.metadata.distribution("context-system")
    except importlib.metadata.PackageNotFoundError:
        return []
    return [] if dist.read_text("direct_url.json") else ["--branch", "v" + dist.version]


def source():
    """The checkout this file sits in, or a fresh shallow clone when installed as a tool."""
    src = Path(__file__).resolve().parent
    if (src / ".context").is_dir():
        return src
    tmp = tempfile.TemporaryDirectory(prefix="context-system-")
    atexit.register(tmp.cleanup)
    cmd = ["git", "clone", "--quiet", "--depth", "1", *release_ref(), REPO_URL, tmp.name]
    try:  # git still chatters on stderr for a shallow tag clone, so keep it unless it failed
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as e:
        why = (getattr(e, "stderr", None) or str(e)).strip()
        sys.exit(f"install: {src} is not a context-system checkout and cloning {REPO_URL} failed:\n{why}")
    return Path(tmp.name)


def main(argv=None):
    ap = argparse.ArgumentParser(usage=USAGE, description=DESCRIPTION,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", nargs="?", default="", metavar="TARGET_REPO")
    ap.add_argument("-y", "--yes", action="store_true")
    ap.add_argument("--no-hook", dest="hook", action="store_false", default=None)
    ap.add_argument("--set-root", action="store_true")
    for f in CLIENT_FLAGS:
        ap.add_argument(f, dest="clients", action="append_const", const=f, default=None)
    a = ap.parse_args(argv)
    got_clients = a.clients is not None
    clients = a.clients or []
    target = Path(a.target).expanduser() if a.target else None

    if a.set_root:
        return set_root(target or Path.cwd(), a.yes)

    src = source()

    if not a.yes and sys.stdin.isatty() and sys.stdout.isatty() and (
            target is None or a.hook is None or not got_clients):
        print(f"\n{M}▌{R} {B}context-system{R} {D}installer{R}\n")
        if target is None:
            target = ask_path(src)
        if a.hook is None:
            a.hook = ask_select("how should the sync loop stay on?", [
                ("hook + skill", "re-injected every prompt, survives compaction (recommended)"),
                ("skill only", "no hook installed, the skill alone drives it")]) == 1
        if not got_clients:
            picks = ask_multi("register the server with other clients?", [
                ("codex", "codex mcp add"), ("gemini", "gemini mcp add"),
                ("antigravity", "agy mcp add"), ("vs code", "code --add-mcp")])
            clients = [CLIENT_FLAGS[p] for p in picks]  # 1-based picks skip --claude at index 0
            print(f"  {D}claude code is covered by .mcp.json, written either way{R}")
        print(f"\n  {C}{target}{R} {D}·{R} hook {'on' if a.hook else 'off'} {D}·{R} clients {' '.join(clients) or 'none'}")
        if (target / ".context/memories").is_dir():
            print(f"  {D}an install is already there; .context/memories/ is kept as is{R}")
        print()
        if not ask_yesno("write it?"):
            print(f"  {Y}! cancelled, nothing written{R}")
            sys.exit(130)
        print()

    hook = True if a.hook is None else a.hook
    target = target or Path.cwd()
    if not target.is_dir():
        sys.exit(f"install: no such directory: {target}")
    target = target.resolve()
    if target == src:
        sys.exit("install: target is the source checkout; pass the repo to install into")

    print(f"{M}▌{R} {B}context-system{R} {D}→{R} {target}\n")

    # --- .context/ ---------------------------------------------------------
    # Everything but memories/, which is the user's data and is handled separately below.
    def skip(d, names):
        top = Path(d) == src / ".context"
        return {n for n in names if n in ("__pycache__", ".DS_Store") or top and (
            n in (".venv", ".pytest_cache", ".sync-on", "memories") or n.startswith("index.db"))}
    shutil.copytree(src / ".context", target / ".context", ignore=skip, dirs_exist_ok=True)
    say(".context/", "server, store code, pyproject")

    # --- .context/memories/ ------------------------------------------------
    # If memories/ is already there we do not touch it at all. Only a fresh install gets the seeds.
    mem = target / ".context/memories"
    if mem.exists():
        if not mem.is_dir():
            sys.exit(f"install: {mem} exists but is not a directory")
        n = sum(1 for f in mem.rglob("*.jsonl") if f.is_file())
        say(".context/memories/", f"kept as is, {n} store{'' if n == 1 else 's'} already there")
    else:
        mem.mkdir(parents=True)
        seeds = sorted((src / ".context/memories").glob("*.jsonl"))
        for f in seeds:
            shutil.copy(f, mem)
        say(".context/memories/", "created, empty: " + " ".join(f.name for f in seeds))

    # --- .mcp.json ---------------------------------------------------------
    p = target / ".mcp.json"
    doc = load_json(p)
    servers = doc.setdefault("mcpServers", {})
    # the server was called "context" before; drop that key so a re-install does not
    # leave two entries launching two processes against the same store
    legacy = servers.get("context")
    stale = bool(legacy) and legacy.get("command") == "uv" and any(".context" in str(x) for x in legacy.get("args", []))
    if stale:
        del servers["context"]
    if servers.get("context-system") == MCP_ENTRY and not stale:
        result = "already present"
    else:
        result = "replaced" if "context-system" in servers else "added"
        servers["context-system"] = MCP_ENTRY
        save_json(p, doc)
        result += ', legacy "context" entry removed' if stale else ""
    say(".mcp.json", f"mcpServers.context-system {result}")

    # --- skill and commands ------------------------------------------------
    skill = src / "skills/context-sync"
    cmds = sorted(skill.glob("commands/*.md"))
    (target / ".claude/skills/context-sync").mkdir(parents=True, exist_ok=True)
    (target / ".claude/commands").mkdir(parents=True, exist_ok=True)
    shutil.copy(skill / "SKILL.md", target / ".claude/skills/context-sync/SKILL.md")
    say(".claude/skills/context-sync/", "SKILL.md")
    # Older hand-installs nested commands/ and hooks/ under the skill, where nothing reads them.
    for old in ("commands", "hooks"):
        d = target / ".claude/skills/context-sync" / old
        if d.is_dir():
            shutil.rmtree(d)
            say(".claude/skills/context-sync/", f"removed stale {old}/")
    for f in cmds:
        shutil.copy(f, target / ".claude/commands")
    say(".claude/commands/", f"{len(cmds)} slash commands")

    # --- .agent/ -----------------------------------------------------------
    # The same skill and commands under the vendor-neutral tree some agents read.
    (target / ".agent/skills/context-sync").mkdir(parents=True, exist_ok=True)
    (target / ".agent/prompts").mkdir(parents=True, exist_ok=True)
    shutil.copy(skill / "SKILL.md", target / ".agent/skills/context-sync/SKILL.md")
    say(".agent/skills/context-sync/", "SKILL.md")
    for f in cmds:
        shutil.copy(f, target / ".agent/prompts")
    say(".agent/prompts/", f"{len(cmds)} prompts")

    # --- hook --------------------------------------------------------------
    if not hook:
        say(".claude/hooks/", "skipped (skill only)")
    else:
        (target / ".claude/hooks").mkdir(parents=True, exist_ok=True)
        h = target / ".claude/hooks/context-sync.sh"
        shutil.copy(skill / "hooks/context-sync.sh", h)
        h.chmod(h.stat().st_mode | 0o111)
        say(".claude/hooks/", "context-sync.sh")

        p = target / ".claude/settings.json"
        doc = load_json(p)
        groups = doc.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
        if any("context-sync.sh" in x.get("command", "") for g in groups for x in g.get("hooks", [])):
            result = "already registered"
        else:
            groups.append({"hooks": [{"type": "command", "command": HOOK_CMD, "timeout": 5}]})
            save_json(p, doc)
            result = "registered"
        say(".claude/settings.json", f"UserPromptSubmit hook {result}")

    # --- summary -----------------------------------------------------------
    print(f"\n  {G}{count['new']} updated{R} {D}·{R} {D}{count['same']} unchanged{R} {D}·{R} {Y}{count['skip']} skipped{R}")
    if not shutil.which("uv"):
        print(f"  {Y}! uv is not on PATH. The server needs it: https://docs.astral.sh/uv/{R}")

    sec("next, in that repo")
    print(f'  {M}1{R}  restart Claude Code and approve the "context-system" server (or /mcp)')
    print(f"  {M}2{R}  {C}/context-start-sync{R}            recall + capture every prompt")
    print(f"     {C}/context-start-sync-readonly{R}   recall only, never writes")
    print(f"     {C}/context-stop-sync{R}             off")
    print(f"  {M}3{R}  commit .context/memories/ with your code; the rest of .context/ is gitignored")

    # --- other agents ------------------------------------------------------
    # Claude Code reads .mcp.json, written above. Every other client is one command
    # away; setup.sh travels with .context/ so teammates without this checkout have it too.
    if clients:
        sec("registering with " + " ".join(clients))
        try:
            subprocess.run(["sh", str(target / ".context/setup.sh"), *clients])
        except OSError:
            print(f"  {Y}! no sh on PATH; run .context/setup.sh {' '.join(clients)} from a shell that has one{R}")
    else:
        sec("other clients")
    print(f"  .context/setup.sh                                   {D}asks: clients, workspace folder{R}")
    print(f"  .context/setup.sh --codex --set-root <folder>       {D}--print just lists the commands{R}")
    print(f"  {ap.prog} <folder> --set-root {' ' * max(0, 30 - len(ap.prog))}{D}finds the repos below a folder, asks which join{R}")


if __name__ == "__main__":
    main()
