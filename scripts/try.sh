#!/usr/bin/env bash
# Open a second, throwaway instance of the installed Heed Fork on fixture data, next to the one you work in.
#
#   scripts/try.sh            # the `tasks` fixture
#   scripts/try.sh pr-storm   # any fixture: tasks, empty, pr-storm, resume, firstrun
#
# A fixture does no IO: no cache, no pk, no gh, no git, no hook socket, no zmx, no preferences or config.toml written.
# The running Heed Fork and its agents are left alone. ⌘Q quits the fixture instance at once.
# HEED_INSTALL_DIR and HEED_INSTALL_NAME as in scripts/install-local.sh.
set -euo pipefail
fixture="${1:-tasks}"
app="${HEED_INSTALL_DIR:-/Applications}/${HEED_INSTALL_NAME:-Heed Fork}.app"
[ -d "$app" ] || { echo "try: $app is not installed (scripts/install-local.sh)" >&2; exit 1; }
open -n "$app" --env "HEED_FIXTURE=$fixture"
