#!/usr/bin/env sh
# Register this folder's MCP server with an AI client, or print the commands.
#   .context/setup.sh                    print every client's command, run nothing
#   .context/setup.sh --codex --gemini   run those; flags: --claude --codex --gemini --agy --vscode
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)   # /abs/path/to/repo/.context
REPO=${HERE%/*}
NAME=context-system
UV=$(command -v uv || echo uv)

DO=1
[ $# -gt 0 ] || { DO=0; set -- --claude --codex --gemini --agy --vscode; }

# run <label> <cmd...>: execute, or print when in print mode or the client is not installed
run() {
  label=$1; shift
  if [ "$DO" = 1 ] && command -v "$1" >/dev/null 2>&1; then
    printf '+ %s\n' "$*"; "$@" || printf '  %s: exited %s (already registered?)\n' "$label" "$?"; return
  fi
  [ "$DO" = 1 ] && printf '  %-12s not on PATH, run later:\n' "$label" || printf '  %-12s' "$label"
  for x; do case $x in *' '*|*'"'*) printf " '%s'" "$x" ;; *) printf ' %s' "$x" ;; esac; done
  echo
}

cd "$REPO"   # project-scoped clients write their config in the cwd
for a in "$@"; do
  case $a in
    # .mcp.json is committed, so paths stay relative and uv unresolved; the rest are user-wide configs, so absolute
    --claude) if [ "$DO" = 1 ] && grep -qs "\"$NAME\"" .mcp.json; then echo "  claude       already in .mcp.json"
              else run claude claude mcp add -s project "$NAME" -- uv run --directory .context python -m context_store.server mcp; fi ;;
    --codex)  run codex       codex mcp add "$NAME" -- "$UV" run --directory "$HERE" python -m context_store.server mcp ;;
    --gemini) run gemini      gemini mcp add "$NAME" -- "$UV" run --directory "$HERE" python -m context_store.server mcp ;;
    --agy)    run antigravity agy mcp add "$NAME" -- "$UV" run --directory "$HERE" python -m context_store.server mcp ;;
    --vscode) run "vs code"   code --add-mcp "{\"name\":\"$NAME\",\"command\":\"$UV\",\"args\":[\"run\",\"--directory\",\"$HERE\",\"python\",\"-m\",\"context_store.server\",\"mcp\"]}" ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "setup: unknown option $a" >&2; sed -n '2,4p' "$0" >&2; exit 2 ;;
  esac
done

[ "$DO" = 1 ] && exit 0
cat <<EOF

  pass a flag to run one, e.g. .context/setup.sh --codex

  clients configured by file (Cursor, Windsurf, Cline, Zed, Claude Desktop) take this in mcpServers:
  "$NAME": {"command": "$UV", "args": ["run", "--directory", "$HERE", "python", "-m", "context_store.server", "mcp"]}
EOF
