#!/usr/bin/env sh
# Install the context system into a repo: store, MCP entry, skill, commands, hook.
# Idempotent — re-run to update an install. An existing .context/memories/ is never touched.
set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET=""
WANT_HOOK=1
CLIENTS=""

usage() {
  cat <<'USAGE'
usage: ./install.sh [TARGET_REPO] [--no-hook] [--claude] [--codex] [--gemini] [--agy] [--vscode]

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
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --no-hook) WANT_HOOK=0 ;;
    --claude|--codex|--gemini|--agy|--vscode) CLIENTS="$CLIENTS $arg" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "install: unknown option $arg" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$TARGET" ] || { echo "install: more than one target given" >&2; exit 2; }
      TARGET=$arg ;;
  esac
done
[ -n "$TARGET" ] || TARGET=$PWD

[ -d "$SRC/.context" ] || { echo "install: run this from a context-system checkout ($SRC has no .context/)" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "install: no such directory: $TARGET" >&2; exit 1; }
TARGET=$(CDPATH= cd -- "$TARGET" && pwd)
if [ "$TARGET" = "$SRC" ]; then
  echo "install: target is the source checkout; pass the repo to install into" >&2
  exit 1
fi

HAVE_PY=1; command -v python3 >/dev/null 2>&1 || HAVE_PY=0
HOOK_CMD='"$CLAUDE_PROJECT_DIR"/.claude/hooks/context-sync.sh'

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$(printf '\033[1m') D=$(printf '\033[2m') R=$(printf '\033[0m')
  C=$(printf '\033[36m') G=$(printf '\033[32m') Y=$(printf '\033[33m') M=$(printf '\033[35m')
else
  B= D= R= C= G= Y= M=
fi
n_new=0 n_same=0 n_skip=0
# sec <title>: section header
sec() { printf '\n%s▌%s %s%s%s\n' "$M" "$R" "$B" "$1" "$R"; }
# say <path> <status>: one row; glyph and color follow the status verb, counted for the summary
say() {
  case $2 in
    *already*|kept*)  g="${D}•" c=$D n_same=$((n_same+1)) ;;
    skipped*)         g="${Y}!" c=$Y n_skip=$((n_skip+1)) ;;
    *added*|*registered|*created*|*replaced*|removed*) g="${G}✔" c=$G n_new=$((n_new+1)) ;;
    *)                g="${G}✔" c=   n_new=$((n_new+1)) ;;
  esac
  printf '  %s%s %s%-28s%s %s%s%s\n' "$g" "$R" "$C" "$1" "$R" "$c" "$2" "$R"
}
printf '%s▌%s %scontext-system%s %s→%s %s\n\n' "$M" "$R" "$B" "$R" "$D" "$R" "$TARGET"

# --- .context/ -------------------------------------------------------------
# Everything but memories/, which is the user's data and is handled separately below.
(cd "$SRC" && tar cf - \
    --exclude '.context/.venv' \
    --exclude '.context/index.db*' \
    --exclude '.context/.pytest_cache' \
    --exclude '.context/.sync-on' \
    --exclude '.context/memories' \
    --exclude '*/__pycache__' \
    --exclude '*.DS_Store' \
    .context) | (cd "$TARGET" && tar xf -)
say .context/ "server, store code, pyproject"

# --- .context/memories/ ----------------------------------------------------
# The user's data. If memories/ is already there we do not touch it at all: no
# seeding, no merging, no new files. Only a fresh install gets the seed stores.
if [ -e "$TARGET/.context/memories" ]; then
  [ -d "$TARGET/.context/memories" ] || {
    echo "install: $TARGET/.context/memories exists but is not a directory" >&2
    exit 1
  }
  n=$(find "$TARGET/.context/memories" -type f -name '*.jsonl' | wc -l | tr -d ' ')
  say .context/memories/ "kept as is, $n store$([ "$n" = 1 ] || echo s) already there"
else
  mkdir -p "$TARGET/.context/memories"
  stores=""
  for f in "$SRC"/.context/memories/*.jsonl; do
    [ -e "$f" ] || continue
    cp "$f" "$TARGET/.context/memories/"
    stores="$stores $(basename -- "$f")"
  done
  say .context/memories/ "created, empty:$stores"
fi

# --- .mcp.json -------------------------------------------------------------
if [ "$HAVE_PY" = 1 ]; then
  result=$(python3 - "$TARGET/.mcp.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
doc = {}
if p.exists() and p.read_text().strip():
    try:
        doc = json.loads(p.read_text())
    except json.JSONDecodeError as e:
        sys.exit(f"{p} is not valid JSON ({e}); fix or move it and re-run")
want = {"command": "uv", "args": ["run", "--directory", ".context", "python", "-m", "context_store.server", "mcp"]}
servers = doc.setdefault("mcpServers", {})
# the server was called "context" before; drop that key so a re-install does not
# leave two entries launching two processes against the same store
legacy = servers.get("context")
stale = bool(legacy) and legacy.get("command") == "uv" and any(".context" in str(a) for a in legacy.get("args", []))
if stale:
    del servers["context"]
if servers.get("context-system") == want and not stale:
    print("already present")
else:
    verb = "replaced" if "context-system" in servers else "added"
    servers["context-system"] = want
    p.write_text(json.dumps(doc, indent=2) + "\n")
    print(verb + (', legacy "context" entry removed' if stale else ""))
PY
)
  say .mcp.json "mcpServers.context-system $result"
else
  say .mcp.json "skipped, no python3. add by hand:" >&2
  echo '    {"mcpServers": {"context-system": {"command": "uv", "args": ["run", "--directory", ".context", "python", "-m", "context_store.server", "mcp"]}}}' >&2
fi

# --- skill and commands ----------------------------------------------------
mkdir -p "$TARGET/.claude/skills/context-sync" "$TARGET/.claude/commands"
cp "$SRC/skills/context-sync/SKILL.md" "$TARGET/.claude/skills/context-sync/SKILL.md"
say .claude/skills/context-sync/ SKILL.md
# Older hand-installs nested commands/ and hooks/ under the skill, where nothing
# reads them. The real copies go to .claude/commands and .claude/hooks below.
for stale in commands hooks; do
  d="$TARGET/.claude/skills/context-sync/$stale"
  if [ -d "$d" ]; then
    rm -rf "$d"
    say .claude/skills/context-sync/ "removed stale $stale/"
  fi
done
cp "$SRC"/skills/context-sync/commands/*.md "$TARGET/.claude/commands/"
ncmd=$(ls -1 "$SRC"/skills/context-sync/commands/*.md | wc -l | tr -d ' ')
say .claude/commands/ "$ncmd slash commands"

# --- .agent/ ---------------------------------------------------------------
# The same skill and commands under the vendor-neutral tree some agents read.
# Commands are called prompts there, so they land in .agent/prompts/.
mkdir -p "$TARGET/.agent/skills/context-sync" "$TARGET/.agent/prompts"
cp "$SRC/skills/context-sync/SKILL.md" "$TARGET/.agent/skills/context-sync/SKILL.md"
say .agent/skills/context-sync/ SKILL.md
cp "$SRC"/skills/context-sync/commands/*.md "$TARGET/.agent/prompts/"
say .agent/prompts/ "$ncmd prompts"

# --- hook ------------------------------------------------------------------
if [ "$WANT_HOOK" = 0 ]; then
  say .claude/hooks/ "skipped (--no-hook)"
else
  mkdir -p "$TARGET/.claude/hooks"
  cp "$SRC/skills/context-sync/hooks/context-sync.sh" "$TARGET/.claude/hooks/context-sync.sh"
  chmod +x "$TARGET/.claude/hooks/context-sync.sh"
  say .claude/hooks/ context-sync.sh

  if [ "$HAVE_PY" = 1 ]; then
    result=$(python3 - "$TARGET/.claude/settings.json" "$HOOK_CMD" <<'PY'
import json, pathlib, sys
p, cmd = pathlib.Path(sys.argv[1]), sys.argv[2]
doc = {}
if p.exists() and p.read_text().strip():
    try:
        doc = json.loads(p.read_text())
    except json.JSONDecodeError as e:
        sys.exit(f"{p} is not valid JSON ({e}); fix or move it and re-run")
groups = doc.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
if any("context-sync.sh" in h.get("command", "")
        for g in groups for h in g.get("hooks", [])):
    print("already registered")
else:
    groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
    p.write_text(json.dumps(doc, indent=2) + "\n")
    print("registered")
PY
)
    say .claude/settings.json "UserPromptSubmit hook $result"
  else
    say .claude/settings.json "skipped, no python3. merge skills/context-sync/hooks/settings-snippet.json by hand" >&2
  fi
fi

# --- summary ---------------------------------------------------------------
printf '\n  %s%s updated%s %s·%s %s%s unchanged%s %s·%s %s%s skipped%s\n' \
  "$G" "$n_new" "$R" "$D" "$R" "$D" "$n_same" "$R" "$D" "$R" "$Y" "$n_skip" "$R"
command -v uv >/dev/null 2>&1 || printf '  %s! uv is not on PATH. The server needs it: https://docs.astral.sh/uv/%s\n' "$Y" "$R"

sec "next, in that repo"
printf '  %s1%s  restart Claude Code and approve the "context-system" server (or /mcp)\n' "$M" "$R"
printf '  %s2%s  %s/context-start-sync%s            recall + capture every prompt\n' "$M" "$R" "$C" "$R"
printf '     %s/context-start-sync-readonly%s   recall only, never writes\n' "$C" "$R"
printf '     %s/context-stop-sync%s             off\n' "$C" "$R"
printf '  %s3%s  commit .context/memories/ with your code; the rest of .context/ is gitignored\n' "$M" "$R"

# --- other agents ----------------------------------------------------------
# Claude Code reads .mcp.json, written above. Every other client is one command
# away; setup.sh travels with .context/ so teammates without this checkout have it too.
if [ -n "$CLIENTS" ]; then
  sec "registering with$CLIENTS"
  # shellcheck disable=SC2086  # CLIENTS is a flag list, splitting is the point
  sh "$TARGET/.context/setup.sh" $CLIENTS
else
  sec "other clients"
  printf '  .context/setup.sh --codex --gemini --agy --vscode   %sno flag prints the commands%s\n' "$D" "$R"
fi
