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

[sessions]
# On launch: ask which tasks' agents to resume (each agent tab resumes its own Claude session), all, or none.
resume_on_launch = "ask"           # ask | always | never
# Typed into a resumed agent that was mid-turn, once it is idle. "" turns it off.
continue_prompt = "Continue where you left off."
# Open a shell in a pane beside the agent in new tasks.
shell_split = false
# Keep every pane's terminal alive in a zmx session, so agents keep running when heed quits, restarts or updates,
# and come back as they were: auto (zmx when it is installed and works; Settings > General shows its check),
# zmx, or none (panes end with heed).
persist = "auto"

[github]
# How often the view on screen refreshes from GitHub; the others refresh five times less often.
poll_seconds = 60

[ui]
# A menu bar item: an owl that shows how many tasks need you, with those tasks and Open Heed.
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

[pk]
# The python of pk's virtualenv. Tasks are pk's notes: Heed reads and changes them through `python -m pk.bridge`.
python = "~/www/pk/.venv/bin/python"

# The agent: claude, overridden field by field. Fields: command, prompt (argument | stdin | paste | file), plan,
# resume ("{id}" is the agent's session id), and [agents.claude.profiles] of name = command line. Other agents run
# in a plain terminal tab, without status.
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"

# Pinned commands: each opens as a tab in a task's worktree when the task gets one; the exit code sets the tab's
# glyph.
[commands]
# jest = "yarn test:jest"

[keys]
# Leaves INSERT. It is also the terminal's quit signal, so pick something else if you need that.
insert_escape = "<C-\\>"
# Brings Heed to the front from any app; "" turns it off.
global_activate = "<C-M-h>"
# Shift+Escape leaves INSERT too; a plain Escape always goes to the terminal. [keys.insert] "<S-Esc>" = "" unbinds.

# Bindings per mode ([keys.normal], [keys.visual], ...) or per view ([keys.tasks], [keys.inbox], [keys.issues],
# [keys.diff], [keys.pr]), in vim notation, each naming a command (the same names : completes). "" unbinds.
# [keys.browser] is for a focused web page: single ⌘ or ⌃ chords, which work while you type in the page too.
# [keys.normal]
# "gB" = ""
# "<C-j>" = "row.next"
```
