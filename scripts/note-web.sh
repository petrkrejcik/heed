#!/usr/bin/env bash
# Rebuild the Note tab's web bundle: web/note (markdown-it + highlight.js) into the one committed file
# Resources/note/note.js. Only needed after changing web/note; Swift builds and tests never need Node.
#
#   scripts/note-web.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/web/note"
if ! command -v npm >/dev/null; then
  echo "note-web: npm not found (Node 20+ is needed to rebuild Resources/note/note.js)" >&2
  exit 1
fi
npm ci --no-audit --no-fund
npm run build
# Mermaid ships its own minified build; the page loads it only for notes with a diagram.
cp node_modules/mermaid/dist/mermaid.min.js "$root/Resources/note/mermaid.js"
# Generate LICENSES.txt for bundled packages.
node -e '
const fs = require("fs"), path = require("path");
const seen = new Set(), out = [];
function walk(name) {
  if (seen.has(name)) return;
  seen.add(name);
  const dir = path.join("node_modules", name);
  if (!fs.existsSync(dir)) return;
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const file = fs.readdirSync(dir).find((f) => /^licen[cs]e/i.test(f));
  out.push(`${pkg.name} ${pkg.version} (${pkg.license})\n\n` + (file ? fs.readFileSync(path.join(dir, file), "utf8").trim() : "(no license file)"));
  Object.keys(pkg.dependencies || {}).forEach(walk);
}
Object.keys(require("./package.json").dependencies).forEach(walk);
out.sort();
fs.writeFileSync("../../Resources/note/LICENSES.txt", "Bundled into note.js and mermaid.js:\n\n" + out.join("\n\n" + "-".repeat(78) + "\n\n") + "\n");
'
echo "note-web: $(wc -c <"$root/Resources/note/note.js" | tr -d ' ') bytes in Resources/note/note.js"
