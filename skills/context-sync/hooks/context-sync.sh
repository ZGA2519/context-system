#!/usr/bin/env sh
# Re-inject the context-sync loop on every prompt while the flag file exists.
# Registered as a UserPromptSubmit hook; stdout is added to the model's context.
# The flag file's contents are the mode: "readonly" for recall-only, anything
# else (including empty) for full recall + capture.
cat > /dev/null  # drain the stdin JSON; leaving it unread can trip the hook handler

FLAG="${CLAUDE_PROJECT_DIR:-.}/.context/.sync-on"
[ -f "$FLAG" ] || exit 0

RECALL="Before answering this prompt: call the context-system MCP select() with a query built from the intent of the prompt, k=6, and treat the results as project ground truth."

if [ "$(tr -d '[:space:]' < "$FLAG")" = "readonly" ]; then
  echo "context-sync is ON in READ-ONLY mode. $RECALL Do not call write() or compress() for any reason this turn, and do not ask for permission to; only an explicit context-start-sync from the user re-enables capture. If something durable comes up, note it in one line instead of storing it. Close the turn with: context: N recalled, read-only. Full protocol is in the context-sync skill."
else
  echo "context-sync is ON. $RECALL After acting: write() each durable fact learned, one per call, correcting in place with write(id=...) rather than appending duplicates. No credentials or personal data. Close the turn with one line: context: N recalled, M written. Full protocol is in the context-sync skill."
fi
