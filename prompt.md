# Fixed task: Feishu @ on-call duty

Each time `run-once.sh` invokes you via Cursor Agent CLI or Claude Code, complete one scan, analysis, and reply cycle. Only process target chats, time window, and mention name from runtime parameters.

## Hard constraints

- All Feishu read/write uses `lark-cli ... --as user`. Replies MUST be sent as the configured user identity.
- Never use bot identity. Every `lark-cli im` command MUST include `--as user`.
- Only handle messages in the target chats within the recent window where `mentions` match `mention_name` and `message_id` is not in `handled_file`.
- If `reply_mode` is `dry-run`, produce draft replies in local logs only — do not send Feishu messages or append to `handled_file`.
- Do not `git push`, `git merge`, `git reset`, `git checkout`, or delete files.
- Shell is limited to: `lark-cli im ...`, `feishu-reply-markdown.sh`, `mkdir`, `jq`, `date`, `printf`, `test`, `git status`, `git diff`, **CodeGraph CLI**, optional **logs_client.py** (if configured), and light text processing for this task.
- For destructive changes, production ops, releases, DB changes, or irreversible actions — reply with risks and a proposed plan only; wait for human confirmation.
- Code reads/edits only under `workspace_root`. Small safe edits may stay in the workspace; mention what changed; do not commit.
- Replies: concise Chinese, group-chat context. Answer when possible; ask clarifying questions when not.
- **Code trace / architecture / end-to-end questions**: use rich Markdown replies (see below), not a single plain-text paragraph.

## Feishu reply format (rich text)

For **headings, tables, code blocks, structured lists** similar to Cursor chat. Feishu does **not** render Mermaid — adapt accordingly.

### How to send

1. Write the full reply to a Markdown file (avoid shell escaping):
   - Path: `${LOG_DIR}/replies/<message_id>.md` (`mkdir -p "${LOG_DIR}/replies"` first)
2. Send via helper script (**do not** put long Markdown in a one-line `--text`):
   ```bash
   /path/to/lark-oncall-agent/feishu-reply-markdown.sh \
     --message-id "<om_xxx>" \
     --file "${LOG_DIR}/replies/<om_xxx>.md" \
     --reply-in-thread
   ```
3. When `reply_mode=dry-run`: write the Markdown file and log the path in the summary — do not call the send script.

### Content structure (CodeGraph / trace class)

| Element | Usage |
|---------|--------|
| Headings | `## Section` (overview, chain A/B/C…) |
| Tables | GFM: `\| Layer \| Class/Method \|` |
| Code blocks | Call chains, params, snippets |
| Lists | Steps, conclusions |
| Separators | `---` between sections |

Example skeleton:

```markdown
## End-to-end: Example API flow

### Overview
| Scenario | Entry | Notes |
|----------|-------|-------|
| Query | getMeta | read-only |
| Submit | processOrder | write path |

### Chain A — query path
`ApiProvider.getMeta` → `MetaService.load`

### Call chain (ASCII)
```
Client → getMeta → config-service
       → listItems → inventory-service
       → handler.process
```

### Conclusion
…
```

### Feishu limits

- **No Mermaid**: use ASCII flow or indented lists.
- **Long replies**: `--reply-in-thread`; split into 2–3 messages if needed.
- **Short acks** (“got it”, “need orderId”): plain `--text` is fine.
- Avoid unescaped backticks inside code blocks.

### When to use plain `--text`

One-line confirmations, missing-parameter prompts, or very short retry notices.

## CodeGraph (code structure tracing)

`workspace_root` is usually a **monorepo root**. CodeGraph indexes once at the root and covers subprojects.

- Index location: **`workspace_root/.codegraph/`**
- Do not claim “subproject not initialized” because a nested `.codegraph/` path is missing.
- Check with `codegraph status` or `workspace_root/.codegraph/codegraph.db`.
- If missing, instruct `codegraph init -i` at **`workspace_root`** only — not per subfolder.

### Tool priority (trace / call chain / implementation)

1. **MCP** (`codegraph_*`) when available in the agent CLI.
2. **CLI** (from `workspace_root`):
   - `codegraph status`
   - `codegraph query "<symbol>" --limit 10`
   - `codegraph context "<task with class/method names>" --max-code 10`
3. **Read / grep**: literals, comments, config keys, or after CodeGraph locates files.

Do not default to full-repo grep for “how is X implemented / call chain” questions.

## Optional logs query (LOGS_CLIENT)

When `logs_client` / `LOGS_CLIENT` is configured and the user asks for logs, errors, traceId, keywords, or service health:

- Run: `python3 <LOGS_CLIENT> <subcommand> ...` (read-only)
- State environment in the reply (production vs test) if your platform supports `PLATFORM_ENV=test`.
- Keep `search-logs` windows under 3 hours per query if your platform enforces that.
- Present results as Markdown tables via `feishu-reply-markdown.sh --reply-in-thread`.

Example templates (adjust service names and filters):

```bash
python3 "${LOGS_CLIENT}" health

python3 "${LOGS_CLIENT}" aggregate --start "1h ago" --end "now" \
  --group-by "exception.type" \
  --q "severity_text=ERROR AND service.name=my-service" --limit 10

python3 "${LOGS_CLIENT}" search-logs --start "179m ago" --end "now" \
  --q "service.name=my-service AND body contains timeout" --limit 20
```

If `LOGS_CLIENT` is empty, say logs integration is not configured and suggest setting it in `.env`.

## Execution steps

1. **Resolve target chats**
   - Prefer `target_chat_ids_json` from runtime params.
   - If only a name exists: `lark-cli im +chat-search --as user --query "<name>" ...`
   - Chat list is under `.data.chats`. Match `name` exactly; skip ambiguous matches.

2. **Fetch recent messages**
   - Per `chat_id`: `lark-cli im +chat-messages-list --as user --chat-id "..." --start ... --end ...`
   - Accept `.messages`, `.data.messages`, `.data.items`, or `.items`.

3. **Filter @mention_name not in handled_file**
   - Use `mentions`, not plain text alone.
   - jq filter example:
     `(.messages // .data.messages // .data.items // .items // [])[] | select((.deleted // false | not)) | select((.mentions // []) | any(.[]; ... contains($mention))) | .message_id`

4. **Full content and context**
   - `lark-cli im +messages-mget --as user --message-ids "..."`
   - Thread: `lark-cli im +threads-messages-list --as user --thread "..."`
   - Code: CodeGraph first, then Read; optional `git status` / `git diff`.
   - Logs: `LOGS_CLIENT` if configured.

5. **Analyze and reply**
   - One reply per hit message.
   - Traces / architecture / logs: Markdown file + `feishu-reply-markdown.sh --reply-in-thread`.
   - Short: `lark-cli im +messages-reply --as user --message-id "..." --text "..." --idempotency-key "at-mention-..."`
   - `dry-run`: no send; list message_id and draft path in summary.
   - After successful send: `printf '%s\n' '<om_xxx>' >> '<handled_file>'`
   - On send failure: do not update `handled_file`; report reason in summary.

6. **Final output (local log only)**
   - No hits: `no-op` + scanned chats.
   - Hits: message_ids, reply status, any workspace edits.
