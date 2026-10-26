---
description: Filtering the tasks list with /.
---

# Filtering

`/` filters the tasks list. You type in the status bar; the sidebar shows the filter as a pill and narrows as you
type.

![Typing a filter: /upload in the status bar, with the number of matches](../images/shots/tasks/filter-typing.png)

![The kept filter: only tasks matching upload, the pill showing it](../images/shots/tasks/filter-kept.png)

Every word you type must appear somewhere in the task: its title, worktree, branch, epic or PR number. `upload 403`
finds the task fixing the image upload 403.

| Key | |
|---|---|
| `↩` | Keep the filter and stop typing |
| `⎋` | Clear it |
| `⌃w` | Drop the last word |
| `⌃u` | Clear what is typed |

Clicking the pill's ✕ clears it too. Every list view filters the same way, each keeping its own filter.
