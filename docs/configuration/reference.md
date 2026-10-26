---
description: Every key in config.toml with its default. Generated from the code.
---

# config.toml reference

`~/.config/heed/config.toml`, as Heed writes it the first time it opens: every key with its default and what
it does. Saving the file applies it right away; a mistake is reported in the status bar and the last good
config stays in use.

This page is generated from the code (`mise run shots`).

```toml
# Heed configuration. Saved changes apply right away; mistakes are reported in the status bar and the last good
# config stays in use. Settings (⌘,) edits this file too, except key bindings, which live only here.

[worktrees]
# Worktrees are created at <root>/<repo>/<name>.
root = "~/code/wt"
# Directories scanned (two levels deep) for repositories.
repo_roots = ["~/Projects", "~/code"]
# Repos outside the roots, added when you import one of their worktrees by path (I in Sessions, :import <path>).
repo_paths = []
# Branches get a prefix picked by the prompt's first word ("Fix broken anchors" → fix/broken-anchors), else this.
# "" means no prefix. The worktree folder uses - for /.
default_prefix = "feature"

[worktrees.prefixes]
fix = ["fix", "bug", "broken", "crash", "repair", "resolve"]
bump = ["bump", "upgrade", "update"]
chore = ["chore", "cleanup", "tidy", "remove", "rename"]
refactor = ["refactor", "restructure", "simplify"]
docs = ["docs", "doc", "document", "readme"]
test = ["test", "tests", "cover"]
perf = ["perf", "speed", "optimize", "faster"]
feature = ["add", "implement", "support", "create", "introduce", "build", "feature"]

[sessions]
default_agent = "claude"
# On launch: ask which sessions to resume, resume them all, or none.
resume_on_launch = "ask"           # ask | always | never
# Typed into a resumed session that was mid-turn, once the agent is idle. "" turns it off.
continue_prompt = "Continue where you left off."
# Open a shell split beside the agent in new sessions (Start work can still toggle it per session).
shell_split = false
# Keep every pane's terminal alive in a zmx session, so agents keep running when heed quits, restarts or updates,
# and come back as they were: auto (zmx when it is installed and works; Settings > General shows its check),
# zmx, or none (panes end with heed).
persist = "auto"

[github]
# How often the view on screen refreshes from GitHub; the others refresh five times less often.
poll_seconds = 60

[issues]
# Which issues the Issues view shows per repo: "involved" (assigned to you or mentioning you) or "all" open
# issues. Override per org ([orgs.<org>] issues = "all") or per repo ([repos."org/name"] issues = "involved");
# the most specific wins. w in Issues (I in Repos) flips the repo under the cursor.
default = "involved"

[ui]
# A menu bar item: an owl that shows how many sessions need you, with those sessions and Open Heed.
menu_bar = true
# The Dock icon shows the same: a badge in the state's colour (blocked, else asking) with the count.
dock_state = true

[tools]
# Where git and gh are. Empty means detect: your login shell's PATH (fish, zsh, bash, nu), then the usual places
# (Homebrew, mise, nix, ~/.local/bin), then /usr/bin. Set a path when detection picks the wrong one.
git = ""                           # e.g. "/opt/homebrew/bin/git"
gh = ""
# Directories searched first, for git, gh and agent commands alike.
path = []

# Agents. The built-in claude can be overridden field by field; any other name is a custom agent, which runs
# without status (only claude reports its state). Fields: command, prompt (argument | stdin | paste | file), plan,
# resume ("{id}" is the agent's session id), and [agents.<name>.profiles] of name = command line.
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"

# [agents.mytool]
# command = "mytool"
# prompt = "argument"

# Org and repo colors: teal, pink, lime, orange, periwinkle, sky. Repos inherit their org's.
# [orgs.elastic]
# color = "teal"
# issues = "all"

# Pinned tasks per repo, each run in its own pane; the exit code sets the tab's glyph.
# [repos."elastic/docs-builder".tasks]
# test = "dotnet test"

[keys]
# Leaves INSERT. It is also the terminal's quit signal, so pick something else if you need that.
insert_escape = "<C-\\>"
# Brings Heed to the front from any app; "" turns it off.
global_activate = "<C-M-h>"
# Shift+Escape leaves INSERT too; a plain Escape always goes to the terminal. [keys.insert] "<S-Esc>" = "" unbinds.

# Bindings per mode ([keys.normal], [keys.visual], ...) or per view ([keys.repos], [keys.inbox], [keys.history],
# [keys.diff], [keys.pr]), in vim notation, each naming a command (the same names : completes). "" unbinds.
# [keys.normal]
# "gB" = ""
# "<C-j>" = "row.next"
```
