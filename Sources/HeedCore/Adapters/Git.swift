import Foundation

/// git, projected into the domain. Every call runs `git` off the main actor and returns domain values; raw output
/// never leaves this namespace. Worktrees are pk's: Heed only reads diffs and commits (`Diff.swift`).
public enum Git {}
