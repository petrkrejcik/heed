---
description: Tasks are your Obsidian notes, through pk. Setting a status, getting a worktree, reviewing a PR, running Kibana.
---

# Status, worktrees and reviews

Every task is a note in your Obsidian vault (`Projects/`, `type: task`). Heed does not keep its own list: it asks
[pk](https://github.com/petrkrejcik/pk) for the tasks, and every change it makes (a new task, a status, a pin, a
worktree, a linked PR) is pk writing the note. Change a note in Obsidian and the sidebar follows within a moment.

Heed runs pk with the python under `[pk]` in config:

```toml
[pk]
python = "~/www/pk/.venv/bin/python"
```

pk's own `PK_*` variables (`PK_OBSIDIAN_VAULT_PATH`, `PK_KIBANA_MAIN`, `PK_KIBANA_WORKTREES`, `PK_KBNI_PORTS`) work
too: Heed asks pk for its paths rather than keeping a copy.

## Status

| Key | |
|---|---|
| `dd` | Done |
| `db` | Blocked |
| `di` | In Progress |
| `dr` | Ready for Review |
| `:status <name>` | Any status: `:status to do`, `:status dropped` (short names work: `wip`, `review`, `drop`) |

Done and Dropped ask first. The task leaves the sidebar and its terminals close, stopping its agents. A review task's
worktree is removed too, unless it holds uncommitted or unpushed work; Heed says what kept it. Ready for Review and
Blocked keep the terminals running.

A status set in Obsidian is followed the same way, except that Heed leaves the terminals of a task marked Done there
alone: they close when you close them.

`:task <words>` goes to the first task matching the words. When none in the sidebar matches, a To Do task that does
is set In Progress and opened.

## A worktree for the task

A new task works in the main Kibana checkout. When it is ready for a branch of its own, `W`:

1. Heed asks the task's agent to write what it learned into the note.
2. When the agent's turn ends (or after three minutes; `W` again skips the wait), pk creates the worktree and its
   branch, named from the title.
3. The same agent moves to the worktree (Heed types Claude's `/cd <worktree>` into it), so the conversation carries
   on there, and it takes your keys.
4. New tabs open in the worktree: `bootstrap` (`pk kbn bootstrap`, with the Node version Kibana asks for) and one per
   [pinned command](panes-and-tabs.md#pinned-commands).

When the task has no running agent (after a relaunch, before resuming), a new agent starts in the worktree instead and
is told to read the note and continue.

## Reviewing a PR

`:review <number>` (or the PR's URL; `⌘V` pastes into the command line) makes the task "Review PR <number> -
<title>" with the PR checked out in a worktree, then opens the `bootstrap` tab and an agent asked to review it.
Marking the review Done removes its worktree.

## Running Kibana

`K` opens a `kibana` tab running `pk kbn` in the task's checkout. pk picks the port; the row's Kibana icon appears once
Kibana answers on it. Heed checks every few seconds.

## Pull requests

When an agent finishes a turn on a task with a branch but no PR, Heed asks pk whether a PR was opened from that
branch, and links it. `heed pr add` and `heed issue add` (and an agent's `gh pr create`) link through pk too.

## Refresh

`r` in the Tasks view reads every note again. Heed also does this at launch, after showing what it had last time.
