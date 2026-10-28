# web/diff

The Diff tab's web view: [CodeMirror 6](https://codemirror.net) with
[`@codemirror/merge`](https://github.com/codemirror/merge), read only. `src/main.ts` is bundled by esbuild into one
minified file, `Resources/diff/diff.js`, which is committed; `scripts/bundle.sh` copies `Resources/diff` into the app
and the tab loads `index.html` from the bundle with `loadFileURL`. Nothing reaches the network.

Swift builds and tests never need Node. Only after changing anything here:

```sh
scripts/diff-web.sh   # npm ci, build diff.js, write Resources/diff/LICENSES.txt
```

Node 20 or newer. `node_modules/` is not committed.

## What the page does

Swift drives it with `callAsyncJavaScript` on `window.heedDiff`; the page answers through the `heed` message
handler. Colours and the font are CSS variables Swift injects at document start (`DiffWebTheme`), so the page has no
colours of its own.

| Call | What it does |
| --- | --- |
| `show({path, language, old, new, mode, keepScroll, focus})` | Draws a file: `mode` is `split` (`MergeView`) or `unified` (`unifiedMergeView`). Unchanged regions collapse (`collapseUnchanged`); `keepScroll` keeps the scroll position (a refresh); `focus` goes to the `first` or `last` hunk. |
| `hunk(delta)` | Next (1) or previous (-1) hunk; false at either end of the file. |
| `setMode(mode)` | The same file in the other mode, on the same hunk. |
| `scrollPage(fraction)` | Scrolls by a fraction of the page (0.5 for `⌃d`). |
| `clear()` | Nothing shown. |

Messages back: `{type: "ready"}` once loaded, `{type: "shown", path, hunks}` after a file is drawn, and
`{type: "cursor", path, line, side, hunk, hunks}` when the hunk on screen or the clicked line changes (`a`, `y` and
`e` act on it).

Languages: TypeScript and TSX, JavaScript and JSX, JSON, CSS, SCSS and Sass, Markdown, YAML, HTML. Others are plain
text.

## Licences

Everything bundled is MIT; `Resources/diff/LICENSES.txt` has each package's licence text, written by
`scripts/diff-web.sh`.

| Package | Licence |
| --- | --- |
| `@codemirror/*` (state, view, language, merge, lang-css, lang-html, lang-javascript, lang-json, lang-markdown, lang-sass, lang-yaml, autocomplete, lint) | MIT |
| `@lezer/*` (common, highlight, lr, css, html, javascript, json, markdown, sass, yaml) | MIT |
| `@marijn/find-cluster-break`, `crelt`, `style-mod`, `w3c-keyname` | MIT |
| `esbuild` (build only, not bundled) | MIT |
