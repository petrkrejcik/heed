#!/usr/bin/env bash
# Rebuild the Diff tab's web bundle: web/diff (CodeMirror 6 + @codemirror/merge) into the one committed file
# Resources/diff/diff.js. Only needed after changing web/diff; Swift builds and tests never need Node.
#
#   scripts/diff-web.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/web/diff"
if ! command -v npm >/dev/null; then
  echo "diff-web: npm not found (Node 20+ is needed to rebuild Resources/diff/diff.js)" >&2
  exit 1
fi
npm ci --no-audit --no-fund
npm run build
# The bundle is minified without comments, so the bundled packages' licences ship next to it.
node -e '
const fs = require("fs"), path = require("path");
const seen = new Set(), out = [];
function walk(name) {
  if (seen.has(name)) return;
  seen.add(name);
  const dir = path.join("node_modules", name);
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const file = fs.readdirSync(dir).find((f) => /^licen[cs]e/i.test(f));
  out.push(`${pkg.name} ${pkg.version} (${pkg.license})\n\n` + (file ? fs.readFileSync(path.join(dir, file), "utf8").trim() : ""));
  Object.keys(pkg.dependencies || {}).forEach(walk);
}
Object.keys(require("./package.json").dependencies).forEach(walk);
out.sort();
fs.writeFileSync("../../Resources/diff/LICENSES.txt", "Bundled into diff.js:\n\n" + out.join("\n\n" + "-".repeat(78) + "\n\n") + "\n");
'
echo "diff-web: $(wc -c <"$root/Resources/diff/diff.js" | tr -d ' ') bytes in Resources/diff/diff.js"
