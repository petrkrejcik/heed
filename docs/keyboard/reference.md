---
description: Every command and its default keys. Generated from the code.
---

# Key reference

Every command Heed has, with its default keys. Keys in parentheses apply in that mode or view only. Any
command can also be run by name on the command line (`:`), and any key changed in `config.toml`; see
[Customizing keys](customizing.md).

This page is generated from the code (`mise run shots`).

## Move & tasks

| Command | Keys | Does |
|---|---|---|
| `row.next` | `j`, `<Down>`, `j` (VISUAL) | next task / row |
| `row.prev` | `k`, `<Up>`, `k` (VISUAL) | previous task / row |
| `row.first` | `gg`, `gg` (VISUAL) | first task / row |
| `row.last` | `G`, `G` (VISUAL) | last task / row |
| `row.halfpage.down` | `<C-d>` | half a page down (ten rows) |
| `row.halfpage.up` | `<C-u>` | half a page up (ten rows) |
| `group.next` | `}` | first row of the next group (sidebar group, repo) |
| `group.prev` | `{` | first row of this group, or of the one before |
| `task.filter` | `/` | filter the current view (typed in the status bar) |
| `filter.clear` |  | clear the current view's filter |
| `task.attention` | `ga` | next task needing you |
| `task.pin` | `m` | pin / unpin task (in its note) |
| `task.back` | `''` | back to previous task |
| `task.open` `<words>` |  | go to the task matching these words; a To Do one becomes In Progress |
| `pin.jump` `<1-9>` | `'1`, `'2`, `'3`, `'4`, `'5`, `'6`, `'7`, `'8`, `'9` | jump to pinned task |
| `task.new` `[title]` | `o` | new task: only a title |
| `task.status` `<done|blocked|in progress|review|todo|dropped>` | `dd`, `db`, `di`, `dr` | set the task's status in its note (done and dropped close its terminals) |
| `task.worktree` | `W` | add a worktree: the agent updates the note, then the worktree, bootstrap and a new agent (again: stop waiting) |
| `task.review` `<number>` |  | review a PR: a task, its worktree, bootstrap and an agent |
| `tasks.refresh` | `r` (tasks) | read every task from pk again |
| `kibana.run` | `K` | run Kibana for this task in a new tab (pk kbn) |
| `resume` |  | pick up where you left off: the agents to resume, as on launch |

## Panes & tabs

| Command | Keys | Does |
|---|---|---|
| `pane.left` | `h`, `<C-w>h` | focus pane left |
| `pane.right` | `l`, `<C-w>l` | focus pane right |
| `pane.up` | `<C-w>k` | focus pane above |
| `pane.down` | `<C-w>j` | focus pane below |
| `pane.split.right` | `<C-w>v` | split right |
| `pane.split.below` | `<C-w>s` | split below |
| `pane.zoom` | `<C-w>z` | zoom pane |
| `pane.close` | `<C-w>q`, `<D-w>` (browser) | close pane |
| `tab.close` |  | close the tab, every pane in it |
| `tab.next` | `gt` | next tab |
| `tab.prev` | `gT` | previous tab |
| `tab.new` | `gn` | new tab with shell |
| `tab.go` `<n>` |  | go to tab n |
| `browser.new` `[url]` | `<D-t>`, `<D-t>` (INSERT) | new tab with a web page (no address: type one) |
| `browser.back` | `<D-[>` (browser) | web page: back |
| `browser.forward` | `<D-]>` (browser) | web page: forward |
| `browser.reload` | `<D-r>` (browser) | web page: reload, or stop loading |
| `browser.location` | `<D-l>` (browser) | web page: type an address |
| `browser.zoom.in` | `<D-=>` (browser), `<D-+>` (browser) | web page: zoom in |
| `browser.zoom.out` | `<D-->` (browser) | web page: zoom out |
| `browser.zoom.reset` |  | web page: actual size |
| `browser.external` |  | web page: open it in your default browser |

## Views & overlays

| Command | Keys | Does |
|---|---|---|
| `view` `<tasks|inbox|issues|prs>` |  | switch view |
| `view.tasks` | `gs` | tasks |
| `view.inbox` | `gm` | inbox |
| `view.issues` | `gi` | issues |
| `view.prs` | `gp` | pull requests |
| `overlay.pr` |  | PR overlay for this task (toggle) |
| `overlay.item` | `go` | open the PR or issue under the cursor; in Tasks, the task's PR (toggle) |
| `overlay.diff` | `gd` | diff overlay: commits, staged, unstaged |
| `overlay.help` | `?`, `<D-/>`, `?` (VISUAL), `<D-/>` (VISUAL), `<D-/>` (INSERT), `<D-/>` (COMMAND) | keys & states |
| `overlay.close` | `<Esc>`, `<Esc>` (diff), `<Esc>` (issue), `<Esc>` (pr) | close overlay |
| `pr.task` | `gS` | jump from a PR to its task |
| `jump.back` | `<C-o>` | back |
| `open.browser` | `gB` | open as a web page in a tab: the item under the cursor; in Tasks its PR or issue (a picker when there are both, Kibana when there are none) |
| `open.repo` | `gR` | open the repo under the cursor on GitHub, as a web page in a tab |
| `links.pick` |  | pick the task's PR or issue to open in the browser |
| `open.reader` | `<CR>` | read inbox item, issue or PR |
| `inspector.toggle` | `zi` | collapse / expand the inspector |
| `sidebar.toggle` | `zs` | collapse / expand the tasks sidebar |
| `config.edit` |  | open config.toml in $EDITOR |
| `agents.stop` |  | stop every agent and shell in every pane (with [sessions] persist = "zmx") |
| `tools.detect` |  | find git and gh again (login shell PATH, usual places, [tools]) |
| `app.quit` |  | quit Heed |
| `settings.open` `[section]` | `<D-,>` | open Settings, on a section (general, agents, keys) |
| `app.activate` |  | bring Heed's window to the front, as the global shortcut does |
| `welcome` |  | show the getting-started checks again |

## Modes

| Command | Keys | Does |
|---|---|---|
| `mode.normal` | `<Esc>` (VISUAL), `<C-\\>` (INSERT), `<S-Esc>` (INSERT), `<Esc>` (COMMAND) | back to NORMAL |
| `mode.insert` | `i` | INSERT into the focused pane |
| `mode.visual` | `v`, `V` | VISUAL: select, then act |
| `mode.command` | `:` | COMMAND line |
| `mode.hint` | `f` | HINT: jump to anything |
| `hint.insert` | `F` | jump and enter INSERT |
| `command.submit` | `<CR>` (COMMAND) | run the command line |
| `command.complete` | `<Tab>` (COMMAND) | complete |

## Selection

| Command | Keys | Does |
|---|---|---|
| `select.toggle` | `<Space>` (VISUAL), `<Space>` (inbox), `<Space>` (issues), `<Space>` (prs) | toggle row |
| `github.sync` | `r` (inbox), `r` (issues), `r` (pr), `r` (prs) | sync GitHub now |
| `items.start` | `s` (VISUAL), `s` (inbox), `s` (issue), `s` (issues) | start one task from the picked items |
| `items.read` | `x` (VISUAL), `x` (inbox) | mark read |
| `items.filter` | `t` (inbox), `t` (issues) | cycle the filter chips |
| `issues.repo.next` | `<Tab>` (issues) | next repo in the Issues repo column |
| `issues.repo.prev` | `<S-Tab>` (issues) | previous repo in the Issues repo column |
| `issues.repo` `[name]` |  | show one repo's issues (no name: every repo) |
| `pr.start` | `S` (pr) | start a new task from this PR |
| `diff.hunk.next` | `n` (diff) | next hunk |
| `diff.hunk.prev` | `N` (diff) | previous hunk |
| `diff.file.next` | `]f` (diff) | next file |
| `diff.file.prev` | `[f` (diff) | previous file |
| `diff.scope.next` | `<Tab>` (diff) | next scope: all, committed, staged, unstaged |
| `diff.scope.prev` | `<S-Tab>` (diff) | previous scope |
| `diff.commit` | `c` (diff) | show one commit (cycles) |
| `diff.split` | `t` (diff) | unified / split |
| `diff.ask` | `a` (diff) | ask the agent about this hunk |
| `diff.copy` | `y` (diff) | copy path:line |
| `diff.edit` | `e` (diff) | open the file in the editor |
