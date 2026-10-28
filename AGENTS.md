# Agents working on Heed

## Principles (from the owner; they decide design questions)

- **Domain driven.** Clean domain models in `HeedCore` (tasks, their layouts and agent tabs, PRs, config) power both
  the UI and the config file. Views render the domain; they never hold their own copy of it.
- **Cache everything, start fast.** The domain is persisted and loaded first, so the window draws the last known state
  immediately; fresh data replaces it as it arrives. Startup never waits on gh, git or the network.
- **Data access is async and projected.** gh, git, the agents' hooks and the filesystem are adapters that run off the
  main actor and project their results into domain values. Raw JSON or command output never reaches a view.
- **Differential UI updates.** Changes land as small domain diffs on `@Observable` models, so only what changed
  redraws. No whole-list replacement when one row changed; stable identities everywhere.
- **The UI starts from a domain value, with no IO.** The window is a function of a domain snapshot plus the input
 state (mode, overlay, cursor). Fixtures are plain domain values (`tasks`, `empty`, `pr-storm`; `resume` is `tasks`
 with its dialog open, `firstrun` is `empty` with its dialog open), so the app can open in any of them for snapshots,
 previews and tests with every adapter (gh, git, sockets, terminals) switched off:
 `HEED_FIXTURE=tasks HEED_SNAPSHOT=out.png`.
- **Never steal focus.** Heed never activates itself or raises a window on its own: not on launch from a hook, not on
  a state change, not when a PR event arrives. Attention is asked for (badge, `ga`, a notification), never taken.

- This is a personal hard fork. Read the PRD first: `/Users/petr/notes/Projects/Heed fork.md`. It wins over this
 file, the upstream brief (`design/BRIEF.md`) and the boards (`design/screens/*.png`, still the visual reference).
 The work is split into tasks, listed in order under the PRD's `## Tasks`; each task's note
 (`/Users/petr/notes/Projects/Heed fork - <task>.md`) holds its plan. Each task gets its own branch from the fork's
 `main`, named after the task, and merges back into it without a PR.
- `mise run test` and `mise run lint` before committing. Without mise, run the tasks' commands from `mise.toml` with
 the env from `mise.local.toml` (this Mac has no mise: it puts zig and the lint tools on the path and sets `TOOLCHAINS`
 so `xcrun metal` works for `scripts/ghostty.sh`). Core logic goes in `HeedCore` with tests; the app layer
  stays thin.
- Never block the main actor: no `Process.waitUntilExit`, file or network IO on it.
- All libghostty calls live in `Sources/HeedTerminal`.
- Keys: add a command to `Commands.all`, bind it in `DefaultKeys`, handle it in `AppModel.perform`. Never handle a key
  anywhere else.
- Check UI against the design with `HEED_SNAPSHOT` (see README).
- GitHub only via `gh`.
