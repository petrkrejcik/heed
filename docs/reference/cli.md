---
description: The heed command line helper.
---

# The heed CLI

`heed` is the small helper bundled inside the app (`Heed.app/Contents/Helpers/heed`). Agents' hooks call it to tell
Heed what they are doing, and every pane has it on its PATH. It sends one line to the app over a local socket and
exits; if the app is not running, the message is dropped. It never slows an agent down: whatever happens, it gives up
after three seconds.

| Command | |
|---|---|
| `heed state <state> [--reason "…"]` | Report a state: working, idle, blocked, asking, done, limited, exited |
| `heed notify "<message>"` | Show a message in the status bar, prefixed with the task |
| `heed pr add <url>` | Set the task's PR, when it has none. One already open for review moves an In Progress task to Ready for Review |
| `heed issue add <url>` | Set the task's issue, when it has none |
| `heed agent-session <agent> <id>` | Record this agent tab's own Claude session id, for resuming |
| `heed command-exit <code>` | Report a pinned command's exit code |
| `heed hook <agent> <event>` | An agent's hook: reads its JSON on stdin |
| `heed tools` | Where `git` and `gh` are found (see [Finding git and gh](../configuration/tools.md)) |
| `heed pk paths\|list\|new <title>\|ready <task>\|watch` | Heed's view of pk's tasks, for scripts: pk's paths, every task, a new task, pk's Ready for Review rule on one task, or the sidebar printed each time it changes. `--python <path>` overrides `[pk] python` |

`heed tools` and `heed pk` talk to no app and have no time limit.

It reads `HEED_SESSION_ID` (the task id), `HEED_PANE_ID` and `HEED_SOCKET` from the environment, which every Heed pane
sets; run elsewhere, it does nothing. The pane id is how a task's agent tabs report apart.
