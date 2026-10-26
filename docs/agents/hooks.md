---
description: How Claude reports its state to Heed, and what Heed passes to it per run.
---

# Hooks

Claude reports what it is doing through hooks: small commands it runs at moments like "about to use a tool"
or "finished the turn". Heed's hook is its bundled `heed` helper, which sends one line to the app over a local socket
and exits; it never slows the agent down and never fails a tool call.

Heed passes its hooks **per run**, on the command line it types into the agent's pane:
`--settings ~/Library/Application Support/Heed/claude-hooks.json` and `--session-id <id>`, a new id for each agent tab.
Nothing in your own Claude configuration is edited.

## What it reports

Every state: working, idle, blocked, asking, done, limited and exited. Each agent tab reports on its own: the hook
names its pane, so a task with two agents shows both. Other agents report nothing; their tabs show the state Heed
assumed when they started.

## Pull requests the agent opens

The same hooks tell Heed when the agent opens a pull request, so it becomes the task's PR at once
(see [A task's PR](../github/task-prs.md)). Heed reads the output of the tool call that ran `gh pr create` (or
`hub pull-request`, or `gh api …/pulls` as a POST), or of a GitHub MCP `create_pull_request`, and takes the PR link
from it (Claude's `PostToolUse` hook: the tool's input and response). A PR the agent only reads or links to is not
taken.

## Inside a pane

Every pane gets its task's id, the socket's path and its own pane id in its environment (`HEED_SESSION_ID` holds the
task id; `HEED_SOCKET`, `HEED_PANE_ID`), and `HEED_BIN` points at the helper. Run outside a Heed pane, the hook does nothing.
See [The heed CLI](../reference/cli.md).
