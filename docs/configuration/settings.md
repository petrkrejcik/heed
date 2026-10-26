---
description: The Settings window, section by section.
---

# Settings

`⌘,` opens Settings. It edits `config.toml` in place, keeping its comments; anything you change in the file shows up
here, and the other way round. Key bindings live only in the file.

![Settings: General](../images/shots/configuration/settings.png)

| Section | Holds |
|---|---|
| **General** | Resume on launch, the continue prompt, shell split, agents outliving Heed (zmx), menu bar item, Dock state, GitHub poll interval, pinned commands (read-only: edited in the file), and where `git` and `gh` are |
| **Agents** | claude's command, prompt delivery and resume arguments |
| **Keys & modes** | The INSERT escape chord and every binding as it stands, read-only: bindings are edited in `config.toml` |

Problems in the file show at the top of Settings as well as in the status bar.
