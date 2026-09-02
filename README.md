# context system

Drop-in project memory for AI sessions: MCP server + vector index + the skill that
keeps a session using them, installed in one step.

```sh
git clone <this repo> && cd context-system
./install.sh /path/to/your-repo
```

That writes the store and MCP server (`.context/`), the `context-system` entry in
`.mcp.json`, the `context-sync` skill, its three slash commands, and the
per-prompt hook. Re-run it to update an install — it never touches
`.context/memories/`. `--no-hook` leaves the loop to the skill alone;
`./install.sh --help` lists what lands where.

Then, in that repo: restart Claude Code, approve the `context-system` server, and
`/context-start-sync`.

Docs: [.context/README.md](.context/README.md) · [skills/context-sync/SKILL.md](skills/context-sync/SKILL.md)
