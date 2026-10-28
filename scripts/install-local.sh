#!/usr/bin/env bash
# Build this checkout in release mode and install it as "Heed Fork.app", so Spotlight (⌘Space, "heed fork") and
# `open -a "Heed Fork"` start the fork next to the original Heed.app from a release.
#
#   scripts/install-local.sh            # build + install + (re)launch is left to you
#   scripts/install-local.sh --open     # ... and open it afterwards
#   scripts/install-local.sh --no-build # reinstall what build/Heed.app already holds
#
# HEED_INSTALL_DIR (default /Applications) and HEED_INSTALL_NAME (default "Heed Fork") change the destination.
# The bundle id stays build.heed.app: both apps share ~/Library/Application Support/Heed and ~/.config/heed, so run
# only one of them at a time.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

build=1
open_after=0
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    --open) open_after=1 ;;
    *) echo "install-local: unknown option $arg" >&2; exit 2 ;;
  esac
done

name="${HEED_INSTALL_NAME:-Heed Fork}"
dir="${HEED_INSTALL_DIR:-/Applications}"
src="${BUILD_DIR:-$root/build}/Heed.app"
dest="$dir/$name.app"

if [ "$build" = 1 ]; then
  swift build -c release
  scripts/bundle.sh release
fi
[ -x "$src/Contents/MacOS/Heed" ] || { echo "install-local: $src is not built" >&2; exit 1; }

mkdir -p "$dir"
# Same name as the original would make Spotlight list two "Heed"s.
rsync -a --delete "$src/" "$dest/"
plist="$dest/Contents/Info.plist"
plutil -replace CFBundleName -string "$name" "$plist"
plutil -replace CFBundleDisplayName -string "$name" "$plist"
# Editing the Info.plist invalidated the ad-hoc signature.
codesign --force --sign - "$dest/Contents/Helpers/heed"
codesign --force --sign - "$dest"

# Make Spotlight pick it up now rather than whenever it next scans.
mdimport "$dest" 2>/dev/null || true

if pgrep -xq Heed; then
  echo "install-local: Heed is running; quit it, then start \"$name\" to get the new build."
fi
echo "install-local: $dest ($(plutil -extract HeedCommit raw "$plist"))"
echo "install-local: start it with Spotlight (⌘Space, \"$name\") or: open -a \"$name\""
[ "$open_after" = 1 ] && open "$dest"
exit 0
