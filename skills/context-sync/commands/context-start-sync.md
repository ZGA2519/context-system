---
description: Start syncing this session with the context MCP project memory
---

Use the `context-sync` skill and run its **context-start-sync** command: verify the
`context-system` MCP server answers, prime the session with a `select`, set the
`.context/.sync-on` flag, then run the per-turn recall/capture loop on every
following prompt until `context-stop-sync`.
