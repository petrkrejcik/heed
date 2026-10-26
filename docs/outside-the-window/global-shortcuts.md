---
description: The shortcut that works from any app.
---

# Global shortcuts

`⌃⌥H` works whichever app is in front: it brings Heed to the front, reopening its window if it was closed.

```toml
[keys]
global_activate = "<C-M-h>"
```

`""` turns it off. It needs at least one of ⌃, ⌥ or ⌘, so it never swallows ordinary typing, and no Accessibility
permission. If another app already owns the combination, the status bar says so.

Heed never takes focus by itself: this shortcut, and clicking a task in the menu bar, are the only times it comes
forward.
