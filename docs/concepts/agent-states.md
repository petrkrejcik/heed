---
description: The states an agent can be in, how Heed knows them, and how they order your tasks.
---

# Agent states

Every agent tab shows its agent's state. A task's row shows the most urgent of its agents; the row stays in its
status's section, and `ga` finds the ones that need you.

| State | Means |
|---|---|
| **working** | The agent is busy. |
| **blocked** | It wants permission to run something and cannot go on without you. |
| **asking** | It has questions for you. |
| **done** | It finished its turn. |
| **idle** | Waiting for a prompt. |
| **limited** | It hit a rate or usage limit. |
| **exited** | The agent's process ended. |

![The sidebar's rows, each with its agent's glyph: asking, working, idle](../images/shots/concepts/states.png)

## Reported or guessed

Claude reports its state through [hooks](../agents/hooks.md): Heed passes it a small command to call as it works.
Until the first hook arrives (an agent just started or resuming), Heed assumes a state and draws it with a dotted
ring. Each agent tab reports on its own, so a task with two agents shows both.

## Where states show

- The sidebar's glyphs, and the inspector's event list.
- The title bar's counts of blocked and asking agents.
- The [Dock badge](../outside-the-window/dock.md) and the [menu bar item](../outside-the-window/menu-bar.md).
- `ga` jumps to the next task that needs you.
