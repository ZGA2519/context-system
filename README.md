# context system

Drop-in project memory for AI sessions: MCP server + vector index + the skill that
keeps a session using them, installed in one step.

```sh
git clone <this repo> && cd context-system
./install.sh
```

It asks where to install, whether to add the per-prompt hook, and which other
clients to register — arrows to move, space to toggle, enter to accept. Whatever
you pass as an argument is not asked for, so `./install.sh /path/to/your-repo -y`
runs straight through with the defaults.

That writes the store and MCP server (`.context/`), the `context-system` entry in
`.mcp.json`, the `context-sync` skill, its three slash commands, and the
per-prompt hook. Re-run it to update an install — it never touches
`.context/memories/`. `--no-hook` leaves the loop to the skill alone;
`./install.sh --help` lists what lands where.

Then, in that repo: restart Claude Code, approve the `context-system` server, and
`/context-start-sync`.

No checkout, or no POSIX sh? The same installer is on PyPI, same flags:

```sh
uvx context-system                    # into the current directory
uvx context-system /path/to/repo -y   # into that repo, defaults, no questions
```

That fetches the release's `.context/` and `skills/` from GitHub, so it needs `git`.
From a checkout, `python3 setup.py` or `uv run context-system` does the same;
`uvx --from git+https://github.com/ZGA2519/context-system context-system` tracks `main`.

## Many repos in one window

One store per repo, but development usually happens with the editor open on the
folder above several of them. Run this inside each repo:

```sh
.context/setup.sh --set-root ..
```

or just `.context/setup.sh`, which asks — same wizard as the installer — which
clients to register and which folder to join.

The repo adds itself to that folder's `.mcp.json` as `context-system-<repo>`, with
an absolute path so the server starts from anywhere, and copies the skill, the
commands and the hook into the folder's `.claude/`. Sync stays per repo: the flag
lives in `<repo>/.context/.sync-on`, and the hook arms only the servers whose repo
has one, so each memory keeps to its own repo.

Docs: [.context/README.md](.context/README.md) · [skills/context-sync/SKILL.md](skills/context-sync/SKILL.md)
