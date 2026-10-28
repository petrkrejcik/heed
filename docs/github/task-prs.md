---
description: How a task gets its pull request and its issue.
---

# A task's PR

A task has one pull request and one issue. The PR shows on the task's sidebar row, in the
[inspector](../tasks/inspector.md) and in the [PR overlay](pr-overlay.md); the issue in the inspector.

## How a task gets them

- **What its agent opened.** When the agent opens a PR (`gh pr create`, or a GitHub MCP `create_pull_request`), its
  hooks tell Heed at once, and the PR becomes the task's. Only an opened PR counts: one the agent reads or links to is
  not. See [Hooks](../agents/hooks.md).
- **By hand.** `heed pr add <url>` or `heed issue add <url>` from inside one of the task's panes (see
  [The heed CLI](../reference/cli.md)).

A task that already has a PR keeps it: a second one does not replace it. The same goes for the issue.

A PR that is open for review when it is linked, or later leaves draft, moves an In Progress task to Ready for Review
(see [Ready for Review by itself](../tasks/status-and-worktrees.md#ready-for-review-by-itself)).

PRs that mention the task's PR (GitHub's cross-references) are listed in the PR overlay under *Also mentions it*.

| Key | |
|---|---|
| `go` | The task's PR in the PR overlay |
| `gS` | From a pull request, jump to its task |
