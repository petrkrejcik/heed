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

Done and Dropped ask first. Its terminals close, stopping its agents, and the task moves under Done (or Dropped) in
the sidebar. A review task's worktree is removed too, unless it holds uncommitted or unpushed work; Heed says what kept
it. Ready for Review and Blocked keep the terminals running.

A status set in Obsidian (or by an agent, or cron) is followed the same way, except that Heed leaves the terminals of a
task marked Done there alone: the task moves to its section with its agents still running, and they close when you
close them.

`:task <words>` goes to the first task matching the words, opening its section if it is collapsed. A To Do task is set
In Progress as it opens; so is one whose first agent you start with `gc`. Moving the cursor onto a To Do task does not
change it.

## A worktree for the task

A new task works in the main Kibana checkout. When it is ready for a branch of its own, `W`:

1. Heed asks the task's agent to write what it learned into the note.
2. When the agent's turn ends (or after three minutes; `W` again skips the wait), pk creates the worktree and its
   branch, named from the title.
3. The same agent moves to the worktree (Heed types Claude's `/cd <worktree>` into it), so the conversation carries
   on there, and it takes your keys.
4. New tabs open in the worktree: `bootstrap` (`pk kbn bootstrap`, with the Node version Kibana asks for) and one per
   [pinned command](panes-and-tabs.md#pinned-commands).

When the task has no running agent (after a relaunch, before resuming), a new agent starts in the worktree instead,
with "Read the task note at … and continue." typed into its input once it is ready. Heed does not send it: the agent
waits until you press Return (or edit or delete the line).

## Reviewing a PR

`:review <number>` (or the PR's URL; `⌘V` pastes into the command line) makes the task "Review PR <number> -
<title>" with the PR checked out in a worktree, then opens the `bootstrap` tab and an agent with "Review <PR>. The task
note is at …" typed into its input, waiting for your Return.
Marking the review Done removes its worktree.

## Running Kibana

`K` opens a `kibana` tab running `pk kbn` in the task's checkout. pk picks the port; the row's Kibana icon appears once
Kibana answers on it. Heed checks every few seconds.

## Pull requests

When an agent finishes a turn on a task with a branch but no PR, Heed asks pk whether a PR was opened from that
branch, and links it. `heed pr add` and `heed issue add` (and an agent's `gh pr create`) link through pk too.

### Ready for Review by itself

An In Progress task moves to Ready for Review when its PR is opened for review: linked while already open and not a
draft, or taken out of draft (Heed sees that in its GitHub poll). The status bar says so, for example *Fix upload is
Ready for Review: PR #123 is open*. pk makes the move, after checking the PR on GitHub.

Only that change moves a task, never the PR's state alone. Set a task back to In Progress (`di`) while its PR is open,
to work on review comments, and it stays In Progress. Tasks in any other status never move, and nothing moves a task
anywhere else: a merged PR does not make it Done.

A PR taken out of draft while Heed was closed still counts at the next launch: Heed compares with the PRs it saw last
time.

## Refresh

`r` in the Tasks view reads every note again. Heed also does this at launch, after showing what it had last time.
