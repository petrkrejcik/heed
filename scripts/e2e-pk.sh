#!/usr/bin/env bash
# End-to-end check of Heed's pk adapter (PkBridge, PkSync, VaultWatcher) against the real pk, in a throwaway
# directory. It reuses pk's own e2e world (pk's scripts/e2e-env.sh): every path pk touches is in a temp folder
# through PK_* variables, and gh, caddy and pgrep are stubs. It never reads or writes the real vault, the Kibana
# checkout or the ports file, and refuses to run if pk reports any path outside its temp folder.
#
#   scripts/e2e-pk.sh            (PK_REPO defaults to ~/www/pk; PYTHON to its .venv python)
set -euo pipefail

heed_repo=$(cd "$(dirname "$0")/.." && pwd)
pk_repo="${PK_REPO:-$HOME/www/pk}"
[[ -f "$pk_repo/scripts/e2e-env.sh" ]] || { echo "e2e: FAIL: no pk at $pk_repo (set PK_REPO)" >&2; exit 1; }

# shellcheck source=/dev/null
source "$pk_repo/scripts/e2e-env.sh"
watch_pid=""
trap '[[ -n "$watch_pid" ]] && { kill "$watch_pid"; wait "$watch_pid" || true; } 2>/dev/null; rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME="$tmp/config"

step "build heed"
(cd "$heed_repo" && swift build --product heed >/dev/null)
heed_bin="$(cd "$heed_repo" && swift build --show-bin-path)/heed"
heed() { "$heed_bin" pk --python "$python" "$@"; }

step "paths come from pk, all inside $tmp"
heed paths >"$tmp/paths"
[[ $(wc -l <"$tmp/paths") -eq 6 ]] || fail "expected six paths: $(cat "$tmp/paths")"
while IFS=$'\t' read -r name path; do
  [[ "$path" == "$tmp"/* ]] || fail "refusing to run: $name is $path, outside $tmp"
done <"$tmp/paths"
grep -q "^projects	$tmp/vault/Projects$" "$tmp/paths" || fail "projects: $(cat "$tmp/paths")"

step "task.list returns the vault's tasks"
pk task new "Seeded task" >/dev/null
seeded="$tmp/vault/Projects/Seeded task.md"
seeded_id=$(sed -n 's/^task_id: //p' "$seeded")
pk task worktree add "$seeded_id" --base main >/dev/null
pk task new "Later task" >/dev/null
sed -i '' 's/^status: In Progress$/status: To Do/' "$tmp/vault/Projects/Later task.md"
heed list >"$tmp/list"
grep -q "^In Progress	Seeded task	" "$tmp/list" || fail "no Seeded task: $(cat "$tmp/list")"
grep -q "^To Do	Later task	" "$tmp/list" || fail "no Later task: $(cat "$tmp/list")"

step "watch the sidebar"
heed watch >"$tmp/watch.log" 2>"$tmp/watch.err" &
watch_pid=$!
sidebar() { grep '^sidebar:' "$tmp/watch.log" | tail -1 || true; }
has() { [[ "$(sidebar)" == *"$1"* ]]; }
lacks() { local line; line=$(sidebar); [[ -n "$line" && "$line" != *"$1"* ]]; }
wait_for() {
  local what=$1
  shift
  for _ in $(seq 1 75); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  fail "$what (sidebar: $(sidebar); stderr: $(cat "$tmp/watch.err"))"
}
wait_for "the first sidebar shows Seeded task" has "Seeded task"
lacks "Later task" || fail "a To Do task is in the sidebar: $(sidebar)"
# FSEvents starts reporting a moment after the stream is created.
sleep 1

step "task.new creates a note and the sidebar shows it"
created=$(heed new "Heed made this")
[[ "$created" == "$tmp/vault/Projects/Heed made this.md" ]] || fail "unexpected note path: $created"
[[ -f "$created" ]] || fail "note was not created"
grep -q '^status: In Progress$' "$created" || fail "the new note is not In Progress"
wait_for "the sidebar shows the new task" has "Heed made this"

step "a task made outside Heed, as the make-task skill does, shows in the sidebar"
outside=$(pk task new "Made in the desktop app" --json --context - <<'PK_CONTEXT'
Uploads fail with 403 for large images.
PK_CONTEXT
)
outside_id=$("$python" -c 'import json, sys; print(json.load(sys.stdin)["task"]["id"])' <<<"$outside")
pk task link "$outside_id" https://github.com/elastic/kibana/issues/299999 --json >/dev/null
outside_note="$tmp/vault/Projects/Made in the desktop app.md"
grep -q '^Uploads fail with 403 for large images.$' "$outside_note" || fail "the context is not in the note"
grep -q '^issue: https://github.com/elastic/kibana/issues/299999$' "$outside_note" || fail "the issue is not linked"
grep -q '^worktree:' "$outside_note" && fail "the task got a worktree"
wait_for "the sidebar shows the task made outside" has "Made in the desktop app"

step "a status changed outside Heed takes the task off the sidebar"
sed -i '' 's/^status: In Progress$/status: Done/' "$created"
wait_for "the Done task leaves the sidebar" lacks "Heed made this"
has "Seeded task" || fail "Seeded task went too: $(sidebar)"

step "a port written into the ports file is picked up"
has "Seeded task [5602]" && fail "port 5602 before it was written: $(sidebar)"
echo "seeded-task:5602" >>"$PK_KBNI_PORTS"
wait_for "the sidebar shows Seeded task on 5602" has "Seeded task [5602]"

[[ ! -s "$tmp/watch.err" ]] || fail "watch reported: $(cat "$tmp/watch.err")"
echo "e2e: OK"
