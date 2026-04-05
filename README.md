# syntex-mcp

MCP server loaded automatically by OpenClaw before every task.

Structures outbound tasks before they reach Syntex by:

1. Reading `SOUL.md` — extracting one sentence relevant to the current task
2. Reading `MEMORY.md` — extracting 2–3 facts relevant to the current task
3. Fetching user preferences from Syntex (`GET /api/user/preferences`)
4. Detecting task type — ROUTINE, INTELLIGENT, SYNTHESIS, or ENGINEERING
5. Structuring the task with labeled fields: `[AGENT]` `[CONTEXT]` `[TASK]` `[DELIVERABLE]` `[SCOPE]` `[SUCCESS]` `[CONSTRAINTS]`
6. Injecting user preferences as hard constraints
7. Suppressing chain-of-thought for ROUTINE and INTELLIGENT tasks

---

## Setup

**Install:**
```bash
npm install
```

**Add to OpenClaw config** (`~/.openclaw/mcp_servers.json` or equivalent):
```json
{
  "syntex-mcp": {
    "command": "node",
    "args": ["/absolute/path/to/syntex-mcp/src/index.js"],
    "env": {
      "SX_TOKEN": "SX-your-token-here"
    }
  }
}
```

**Required env var:**
- `SX_TOKEN` — your Syntex bearer token (format: `SX-xxxxxxxxxxxxxxxx`)

**Optional env var:**
- `OC_WORKING_DIR` — explicit path to the directory containing `SOUL.md` and `MEMORY.md` (fallback if MCP roots are unavailable)

---

## Tool

### `structure_task`

**Input:**
```json
{ "task": "your raw task text" }
```

**Output:** A structured task block ready to send to a model:
```
[AGENT]
<one sentence from SOUL.md most relevant to the task>

[CONTEXT]
1. <most relevant MEMORY.md fact>
2. <second most relevant fact>
3. <third most relevant fact>

[TASK]
<original task text>

[DELIVERABLE]
<tier-appropriate deliverable specification>

[SCOPE]
<execution bounds>

[SUCCESS]
<success criteria>

[CONSTRAINTS]
Length: ...
Format: ...
Tone: ...
[No chain-of-thought. Do not narrate your reasoning. Answer directly.]  ← ROUTINE and INTELLIGENT only
```

---

## RISE Tier Detection

| Tier | Name | Key Test |
|---|---|---|
| R | ROUTINE | Could a simple script do this? |
| I | INTELLIGENT | Needs writing skill but nothing outside the prompt? |
| S | SYNTHESIS | Needs to go outside the prompt to complete? |
| E | ENGINEERING | Would a senior expert charge a premium? |

Detection is deterministic — no LLM call. Uses the same pre-filter as `classify.js`.

---

## Syntex Server Dependency

The preferences fetch targets `GET https://syntexprotocol.com/api/user/preferences`.

This endpoint needs to be added to `api/user.js` in the Syntex server. It should return:
```json
{
  "lengthPreference": "balanced",
  "formatPreference": "task_appropriate",
  "tonePreference":   "direct",
  "tierProfile":      "smart"
}
```

The MCP server falls back to these same defaults if the endpoint is unavailable.
