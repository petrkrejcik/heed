---
description: Where Heed keeps its configuration, cache and other files.
---

# Files and locations

| Path | |
|---|---|
| `~/.config/heed/config.toml` | Configuration (or under `$XDG_CONFIG_HOME`) |
| `~/Library/Application Support/Heed/domain.json` | Tasks, their layouts and agent tabs, and the last GitHub sync, cached for a fast start |
| `~/Library/Application Support/Heed/heed.sock` | The socket hooks report to |
| `~/Library/Application Support/Heed/claude-hooks.json` | The hook settings passed to claude per run |
| `~/Library/Caches/Heed/avatars` | Org avatars |

Deleting the cache loses the tasks' tab layouts and agent session ids; the GitHub part comes back with the next sync. Heed keeps no transcripts; agents keep their own.
