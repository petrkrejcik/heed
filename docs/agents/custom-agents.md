---
description: Changing the built-in claude agent and adding your own.
---

# Custom agents

Every agent is an `[agents.<name>]` table. The built-in claude can be changed field by field; any other name adds an
agent. Only claude reports its state; a custom agent runs without one.

```toml
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"

[agents.mytool]
command = "mytool --model fast"
prompt = "argument"
```

| Field | |
|---|---|
| `command` | The command line that starts the agent. |
| `prompt` | How the prompt reaches it: `argument` (appended), `stdin` (piped in), `paste` or `file`. |
| `plan` | Arguments for **Plan first** in Start work. |
| `resume` | Arguments that resume a session; `{id}` is the agent's session id. Without it, a resumed session starts fresh. |
| `[agents.<name>.profiles]` | Named command lines, `name = "command"`. |

`default_agent` under `[sessions]` picks the agent Start work selects first. Settings (`⌘,`) edits the same fields.
