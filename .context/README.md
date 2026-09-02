# .context

Project memory that every AI session and every model shares, versioned with the code it describes.

```
memories/<scope>.jsonl   the store: one memory per line, committed, git is the history
index.db                 sqlite-vec vector index, gitignored, rebuilt from the JSONL when they drift
context_store/store.py   the four operations
context_store/server.py  MCP server (stdio or HTTP) and a JSON API over the same store
```

## Install in a project

Copy this folder to the repo root as `.context/` and put `.mcp.json` next to it:

```json
{"mcpServers": {"context": {"command": "uv", "args": ["run", "--project", ".context", "context", "mcp"]}}}
```

Needs [uv](https://docs.astral.sh/uv/). The first `uv run` builds `.venv/` and downloads the embedding model (about 30 MB) into `$FASTEMBED_CACHE_PATH`, or the temp dir if unset. Commit `memories/`; the `.gitignore` in this folder drops everything else.

## Connect

Claude Code reads `.mcp.json` and starts the server itself. Any other MCP client over stdio:

```sh
uv run --project .context context mcp
```

As a service, JSON API with docs at `/docs` and MCP at `/mcp`:

```sh
uv run --project .context context serve            # http://127.0.0.1:8765
curl -s localhost:8765/select -d '{"query":"how is auth done"}' -H 'content-type: application/json'
```

## Operations

| op | args | does |
| --- | --- | --- |
| `write` | text, scope=main, tags | Save one fact. Returns the memory with its id. |
| `select` | query, scope=main, k=8, tags | Semantic search, best first with a score. Empty query lists the k newest. |
| `compress` | scope, ids, summary, threshold=0.92 | ids + summary: replace them with one summary in scope. Nothing: merge near-duplicates, newest kept. |
| `isolate` | scope, seed_from, query, k, tags | Open a private scope, optionally seeded with the top k memories of another. |

Scope names are `[a-z0-9._-]`, one JSONL file each. `main` is the shared default.

## Workflow

1. Session start: `select(query="what I am about to do")`.
2. While working: `write` each decision, gotcha or preference as you learn it.
3. Sub-task or sub-agent: `isolate("task-x", seed_from="main", query=...)`, work inside that scope, then `compress("main", ids, summary)` to fold it back.
4. Now and then: `compress()` to merge duplicates.

## Notes

- Test the install on a new machine: `uv run --group dev pytest`.
- Delete a memory by removing its line from the JSONL. The index resyncs on the next call.
- Merge conflicts in a JSONL: keep both sides, ids are unique, then run `compress()`.
- `CONTEXT_EMBED_MODEL` picks any fastembed model. Changing it rebuilds the index.
- The server holds no LLM. Summaries come from the model calling `compress`, so any model can be the summariser.
