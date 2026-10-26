---
navigation_title: Agents
description: The coding agent Heed runs, and how it tells Heed what it is doing.
---

# Agents

Heed runs Claude Code in real terminals and keeps track of what it is doing. Claude is the only agent with hooks, so
it is the only one whose state Heed shows.

| Agent | Command | Reports its state through | Resumes with |
|---|---|---|---|
| claude | `claude` | Hooks passed with `--settings` | `--resume <id>` |

Any other command line agent can still run in a plain terminal tab, but without a state.

- [Hooks](hooks.md): what Heed passes to Claude, and why your own Claude config never changes.
- [Configuring claude](configuring-claude.md): changing claude's command line.
