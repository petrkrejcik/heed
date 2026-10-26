---
description: How Claude reports its state to Heed, and what Heed passes to it per run.
---

# Hooks

Claude reports what it is doing through hooks: small commands it runs at moments like "about to use a tool"
or "finished the turn". Heed's hook is its bundled `heed` helper, which sends one line to the app over a local socket
and exits; it never slows the agent down and never fails a tool call.

Heed passes its hooks **per run**, on the command line it types into the agent's pane:
`--settings ~/Library/Application Support/Heed/claude-hooks.json` and `--session-id <id>`. Nothing in your own Claude
configuration is edited.

The command preview at the bottom of [Start work](../start-work/agent-and-options.md) shows exactly what will run.

## What it reports

Every state: working, idle, blocked, asking, done, limited and exited. Other agents report nothing; their sessions show
the state Heed assumed when they started.

## Pull requests the agent opens

The same hooks tell Heed when the agent opens a pull request, so its session tracks it at once, in whatever repo it is
(see [Tracking PRs](../github/tracking-prs.md)). Heed reads the output of the tool call that ran `gh pr create` (or
`hub pull-request`, or `gh api …/pulls` as a POST), or of a GitHub MCP `create_pull_request`, and takes the PR link
from it (Claude's `PostToolUse` hook: the tool's input and response). A PR the agent only reads or links to is not
taken.

## Inside a pane

Every pane gets the session's id, the socket's path and its own pane id in its environment (`HEED_SESSION_ID`,
`HEED_SOCKET`, `HEED_PANE_ID`), and `HEED_BIN` points at the helper. Run outside a Heed pane, the hook does nothing.
See [The heed CLI](../reference/cli.md).
