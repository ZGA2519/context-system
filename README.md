# context system

Project memory for AI coding sessions. Lives in the repo, travels with the code,
shared by every model that opens it, consulted on every prompt.

Every AI session starts from zero. The decision you argued out yesterday gets
re-argued today, the gotcha that cost an afternoon gets hit again next week, and
the convention nobody wrote down gets broken by the next model to touch the code.
This fixes that with three small pieces:

- **a store**: `.context/memories/*.jsonl`, one fact per line, committed. Git is the history.
- **a server**: an MCP server over that store with four tools and a sqlite-vec index for semantic recall.
- **a discipline**: a skill and a hook that make the session recall *before* it answers and capture *after* it acts, every prompt, until told to stop.

## Quick start

```sh
cd your-repo
uvx context-system -y
```

Restart Claude Code, approve the `context-system` server when asked, then:

```
/context-start-sync
```

That is the whole setup. Needs [uv](https://docs.astral.sh/uv/) and `git`.
Drop the `-y` to be asked about the target, the hook and the other clients instead
of taking the defaults.

What landed in the repo:

| path | what |
| --- | --- |
| `.context/` | the store and the MCP server, with an empty `memories/main.jsonl` |
| `.mcp.json` | the `context-system` server entry, merged into whatever was there |
| `.claude/skills/context-sync/` | the skill that drives the per-prompt loop |
| `.claude/commands/context-*.md` | `/context-start-sync`, `/context-start-sync-readonly`, `/context-stop-sync` |
| `.claude/hooks/context-sync.sh` + `settings.json` | a `UserPromptSubmit` hook that re-arms the loop every prompt, so it survives compaction |
| `.agent/` | the same skill and commands under the vendor-neutral tree some agents read |

Commit `.context/memories/`. Everything else under `.context/` is gitignored.
Re-run the command any time to update an install; `memories/` is never touched.

## What a session looks like

With sync on, every prompt ends with one quiet line:

```
context: 6 recalled · 1 written
```

Before answering, the model ran one `select` with a query built from the *intent*
of your prompt and treated the hits as ground truth for this repo. If a stored
decision contradicts what it was about to do, it says so instead of quietly
overwriting it. After acting, it wrote the durable facts it learned, one per call,
correcting older memories in place rather than appending near-duplicates.

A memory is one JSON line:

```json
{"id": "9f3c1a7be2d4", "ts": "2026-09-09T07:20:05+00:00", "text": "Session tokens are refreshed by the gateway, never by services. Tried per-service refresh first; it raced under load.", "tags": ["auth", "decision"], "source": ""}
```

Durable, so it gets written: a decision and why, the option that lost, a hard
constraint, a gotcha and its workaround, a convention the code does not reveal, a
stated preference. Not durable, so it does not: transient state, file contents,
anything re-derivable by reading the repo, general knowledge. Never: credentials,
tokens, personal data. The store is committed and pushed.

Three commands:

| command | does |
| --- | --- |
| `/context-start-sync` | recall and capture on every prompt |
| `/context-start-sync-readonly` | recall only, writes nothing, ever. For someone else's repo, or a branch whose decisions are not settled |
| `/context-stop-sync` | final flush of anything durable, then off |

## The four operations

Any MCP client gets the same four tools. Scopes are named JSONL files; `main` is the shared default.

| tool | args | does |
| --- | --- | --- |
| `select` | `query`, `scope=main`, `k=8`, `tags` | Semantic search, best first, each with a score. Empty query lists the `k` newest. |
| `write` | `text`, `scope=main`, `tags`, `source`, `id` | Save one fact. Pass an existing `id` to replace that memory in place. |
| `compress` | `scope`, `ids`, `summary`, `threshold=0.92` | `ids` + `summary`: fold those memories into one. Neither: merge near-duplicates, newest kept. |
| `isolate` | `scope`, `seed_from`, `query`, `k`, `tags` | Open a private scope, optionally seeded with the top `k` hits from another. |

A sub-task or a sub-agent that will generate a lot of throwaway reasoning gets
`isolate("task-x", seed_from="main", query=...)`, works in that scope, then
`compress("main", ids, summary)` folds the useful residue back.

## Why it is shaped like this

**Memory is part of the repo.** A branch has its own memory. A pull request
reviews the memory along with the code. `git blame` on a decision works. Merge
conflicts in a JSONL are trivial: keep both sides, ids are unique, run `compress()`.

**No model inside the server.** Summaries in `compress` come from whichever model
is calling. Claude writes a memory, Codex reads it, Gemini corrects it. Same store,
same file.

**The index is disposable.** `index.db` is a sqlite-vec index rebuilt from the JSONL
whenever they drift. Delete it freely. Embeddings come from
`BAAI/bge-small-en-v1.5` via fastembed, about 30 MB, downloaded on first run;
`CONTEXT_EMBED_MODEL` picks another.

**The skill solves *when*, the hook makes it stick.** A memory server on its own
gets called whenever the model happens to think of it, which on a long session
means less and less. The skill turns it into a fixed per-turn loop. The hook
re-injects that loop on every prompt for as long as `.context/.sync-on` exists,
so compaction cannot erode it.

## Many repos in one window

One store per repo, but the editor is usually open on the folder above several.
From that folder:

```sh
uvx context-system --set-root        # finds every repo with a .context/ up to 5 levels down, asks which join
```

or inside each repo, `.context/setup.sh --set-root ..`. Either way the repo adds
itself to that folder's `.mcp.json` as `context-system-<repo>` with an
absolute path, and copies the skill, commands and hook into the folder's `.claude/`.
Stores stay separate on purpose: one repo's decisions are not another's. Sync is
per repo too, so one repo can be capturing while another is read-only and the rest
are off.

## Other clients

Claude Code reads `.mcp.json` and is done. Everything else is one command away,
and `setup.sh` ships inside `.context/` so teammates without this repo have it:

```sh
.context/setup.sh                      # asks: which clients, which workspace folder
.context/setup.sh --codex --gemini     # also --claude --agy --vscode
.context/setup.sh --print              # just list the commands
```

Clients configured by file (Cursor, Windsurf, Cline, Zed, Claude Desktop) take
this under `mcpServers`:

```json
"context-system": {"command": "uv", "args": ["run", "--directory", "/abs/path/to/repo/.context", "python", "-m", "context_store.server", "mcp"]}
```

As a service, a JSON API with docs at `/docs` and MCP at `/mcp`:

```sh
uv run --directory .context python -m context_store.server serve     # http://127.0.0.1:8765
curl -s localhost:8765/select -d '{"query":"how is auth done"}' -H 'content-type: application/json'
```

## Other ways to install

All of these are the same installer with the same flags. `uvx` fetches the release
tag from GitHub, so it needs `git`; the rest run from a checkout.

```sh
uvx context-system /path/to/repo -y                 # a repo other than the current one
uvx context-system --no-hook                        # skill only, no hook
uvx context-system --codex --vscode                 # register those clients as you go
uvx --from git+https://github.com/ZGA2519/context-system context-system   # track main

git clone https://github.com/ZGA2519/context-system && cd context-system
./install.sh /path/to/repo        # POSIX sh, the original, arrow-key wizard
python3 setup.py /path/to/repo    # same thing in Python, plain prompts, works in cmd.exe
uv run context-system --help      # everything the installer accepts
```

## Under the hood

```
.context/
  memories/<scope>.jsonl    the store, committed
  index.db                  sqlite-vec index, gitignored, rebuilt when it drifts
  context_store/store.py    the four operations
  context_store/server.py   MCP over stdio, or HTTP with a JSON API
  setup.sh                  client registration and workspace folders
skills/context-sync/        the skill, commands and hook the installer copies
install.sh · setup.py       the installer, twice
```

Tests: `uv run --group dev pytest` inside `.context/` for the store,
`python3 test_setup.py` at the root for the installer.

Docs: [.context/README.md](https://github.com/ZGA2519/context-system/blob/main/.context/README.md) for the store and server,
[skills/context-sync/SKILL.md](https://github.com/ZGA2519/context-system/blob/main/skills/context-sync/SKILL.md) for the full per-turn protocol.

## Releasing

Bump `version` in `pyproject.toml`, push to `main`. The workflow in
`.github/workflows/publish.yml` tags `v<version>`, builds and publishes to PyPI with
trusted publishing. A push that does not change the version does nothing.

## License

[MIT](https://github.com/ZGA2519/context-system/blob/main/LICENSE.txt)
