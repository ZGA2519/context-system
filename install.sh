#!/usr/bin/env sh
# Install the context system into a repo: store, MCP entry, skill, commands, hook.
# Idempotent — re-run to update an install. Never overwrites .context/memories/.
set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET=""
WANT_HOOK=1

usage() {
  cat <<'USAGE'
usage: ./install.sh [TARGET_REPO] [--no-hook]

Installs into TARGET_REPO (default: the current directory):

  .context/                             the store and MCP server
  .mcp.json                             mcpServers.context, merged in
  .claude/skills/context-sync/          the skill
  .claude/commands/context-*.md         /context-start-sync, -readonly, /context-stop-sync
  .claude/hooks/context-sync.sh         per-prompt loop re-injection
  .claude/settings.json                 the UserPromptSubmit hook, merged in

  --no-hook   skip the last two; the skill alone drives the loop
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --no-hook) WANT_HOOK=0 ;;
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

echo "installing the context system into $TARGET"

# --- .context/ -------------------------------------------------------------
# Everything but memories/, which is the user's data and is merged file by file.
(cd "$SRC" && tar cf - \
    --exclude '.context/.venv' \
    --exclude '.context/index.db*' \
    --exclude '.context/.pytest_cache' \
    --exclude '.context/.sync-on' \
    --exclude '.context/memories' \
    --exclude '*/__pycache__' \
    --exclude '*.DS_Store' \
    .context) | (cd "$TARGET" && tar xf -)
echo "  .context/                    server, store code, pyproject"

mkdir -p "$TARGET/.context/memories"
for f in "$SRC"/.context/memories/*.jsonl; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  if [ -e "$TARGET/.context/memories/$base" ]; then
    n=$(grep -c '' "$TARGET/.context/memories/$base" || true)
    echo "  .context/memories/$base kept, $n stored"
  else
    cp "$f" "$TARGET/.context/memories/$base"
    echo "  .context/memories/$base new empty store"
  fi
done

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
want = {"command": "uv", "args": ["run", "--project", ".context", "context", "mcp"]}
servers = doc.setdefault("mcpServers", {})
if servers.get("context") == want:
    print("already present")
else:
    verb = "replaced" if "context" in servers else "added"
    servers["context"] = want
    p.write_text(json.dumps(doc, indent=2) + "\n")
    print(verb)
PY
)
  echo "  .mcp.json                    mcpServers.context $result"
else
  echo "  .mcp.json                    SKIPPED, no python3 — add by hand:" >&2
  echo '    {"mcpServers": {"context": {"command": "uv", "args": ["run", "--project", ".context", "context", "mcp"]}}}' >&2
fi

# --- skill and commands ----------------------------------------------------
mkdir -p "$TARGET/.claude/skills/context-sync" "$TARGET/.claude/commands"
cp "$SRC/skills/context-sync/SKILL.md" "$TARGET/.claude/skills/context-sync/SKILL.md"
echo "  .claude/skills/context-sync/ SKILL.md"
# Older hand-installs nested commands/ and hooks/ under the skill, where nothing
# reads them. The real copies go to .claude/commands and .claude/hooks below.
for stale in commands hooks; do
  d="$TARGET/.claude/skills/context-sync/$stale"
  if [ -d "$d" ]; then
    rm -rf "$d"
    echo "  .claude/skills/context-sync/ removed stale $stale/"
  fi
done
cp "$SRC"/skills/context-sync/commands/*.md "$TARGET/.claude/commands/"
echo "  .claude/commands/            $(ls -1 "$SRC"/skills/context-sync/commands/*.md | wc -l | tr -d ' ') slash commands"

# --- hook ------------------------------------------------------------------
if [ "$WANT_HOOK" = 0 ]; then
  echo "  .claude/hooks/               skipped (--no-hook)"
else
  mkdir -p "$TARGET/.claude/hooks"
  cp "$SRC/skills/context-sync/hooks/context-sync.sh" "$TARGET/.claude/hooks/context-sync.sh"
  chmod +x "$TARGET/.claude/hooks/context-sync.sh"
  echo "  .claude/hooks/               context-sync.sh"

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
    echo "  .claude/settings.json        UserPromptSubmit hook $result"
  else
    echo "  .claude/settings.json        SKIPPED, no python3 — merge skills/context-sync/hooks/settings-snippet.json by hand" >&2
  fi
fi

command -v uv >/dev/null 2>&1 || echo "
note: uv is not on PATH. The server needs it: https://docs.astral.sh/uv/"

cat <<'NEXT'

done. In that repo:
  1. restart Claude Code, and approve the "context" server when asked (or /mcp)
  2. /context-start-sync          recall + capture every prompt
     /context-start-sync-readonly recall only, never writes
     /context-stop-sync           off
  3. commit .context/memories/ with your code; the rest of .context/ is gitignored
NEXT
