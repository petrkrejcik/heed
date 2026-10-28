// The Diff tab's web view. Swift hands it a file's old and new contents (`heedDiff.show`) and drives it with commands
// (`hunk`, `setMode`, `scrollPage`); it reports the hunk or line you are on back through the `heed` message handler,
// so Swift's `a`, `y` and `e` know the line. Read-only: nothing here edits a document. The colours and the font are
// CSS variables Swift sets before this runs (`--heed-*`), so a light theme only swaps their values.
import { css } from "@codemirror/lang-css";
import { html } from "@codemirror/lang-html";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { sass } from "@codemirror/lang-sass";
import { yaml } from "@codemirror/lang-yaml";
import { HighlightStyle, type LanguageSupport, syntaxHighlighting } from "@codemirror/language";
import { type Chunk, getChunks, MergeView, unifiedMergeView } from "@codemirror/merge";
import { EditorState, type Extension, StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, highlightSpecialChars, lineNumbers } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";

type Mode = "split" | "unified";

interface Payload {
  path: string;
  /** A name from Swift's `DiffLanguage` (typescript, tsx, json, …); null is plain text. */
  language: string | null;
  old: string;
  new: string;
  mode: Mode;
  /** Re-reading the same file: keep where it was scrolled to. */
  keepScroll?: boolean;
  /** Go to the first or last hunk once drawn (`n` past a file's last hunk lands on the next file's first). */
  focus?: "first" | "last" | null;
}

interface Target {
  chunk: number;
  /** A line clicked, when that is what you are on (1-based, on side `side`). */
  line?: number;
  side?: "a" | "b";
}

declare global {
  interface Window {
    heedDiff: typeof api;
    webkit?: { messageHandlers?: { heed?: { postMessage(message: unknown): void } } };
  }
}

function post(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.heed?.postMessage(message);
}

const languages: Record<string, () => LanguageSupport> = {
  typescript: () => javascript({ typescript: true }),
  tsx: () => javascript({ typescript: true, jsx: true }),
  javascript: () => javascript(),
  jsx: () => javascript({ jsx: true }),
  json: () => json(),
  css: () => css(),
  scss: () => sass(),
  sass: () => sass({ indented: true }),
  markdown: () => markdown(),
  yaml: () => yaml(),
  html: () => html(),
};

const syntax = HighlightStyle.define([
  {
    tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword, t.modifier, t.self],
    color: "var(--heed-syntax-keyword)",
  },
  { tag: [t.bool, t.null, t.atom], color: "var(--heed-syntax-keyword)" },
  { tag: [t.string, t.special(t.string), t.regexp, t.character, t.url], color: "var(--heed-syntax-string)" },
  { tag: [t.number, t.integer, t.float, t.unit], color: "var(--heed-syntax-number)" },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--heed-syntax-comment)" },
  { tag: [t.meta, t.processingInstruction, t.annotation], color: "var(--heed-syntax-comment)" },
  { tag: [t.typeName, t.className, t.namespace, t.labelName], color: "var(--heed-syntax-type)" },
  {
    tag: [t.function(t.variableName), t.function(t.propertyName), t.function(t.definition(t.variableName))],
    color: "var(--heed-syntax-function)",
  },
  { tag: [t.tagName], color: "var(--heed-syntax-tag)" },
  { tag: [t.attributeName], color: "var(--heed-syntax-type)" },
  { tag: [t.heading], color: "var(--heed-syntax-keyword)", fontWeight: "bold" },
  { tag: [t.emphasis], fontStyle: "italic" },
  { tag: [t.strong], fontWeight: "bold" },
  { tag: [t.link], color: "var(--heed-syntax-string)", textDecoration: "underline" },
  { tag: [t.invalid], color: "var(--heed-deleted)" },
]);

const theme = EditorView.theme(
  {
    "&": {
      color: "var(--heed-code)",
      backgroundColor: "var(--heed-bg)",
      fontSize: "var(--heed-font-size)",
      height: "100%",
    },
    ".cm-scroller": { fontFamily: "var(--heed-font)", lineHeight: "1.6" },
    ".cm-content": { caretColor: "transparent", padding: "6px 0 40px" },
    "&.cm-focused": { outline: "none" },
    ".cm-gutters": { backgroundColor: "var(--heed-bg)", color: "var(--heed-gutter)", border: "none" },
    ".cm-lineNumbers .cm-gutterElement": { padding: "0 10px 0 14px", minWidth: "36px" },
    ".cm-activeLine, .cm-activeLineGutter": { backgroundColor: "transparent" },
    ".cm-selectionBackground, &.cm-focused .cm-selectionBackground, ::selection": {
      backgroundColor: "var(--heed-selection) !important",
    },
    "&.cm-merge-a .cm-changedLine, .cm-deletedChunk": { backgroundColor: "var(--heed-deleted-line)" },
    "&.cm-merge-b .cm-changedLine, .cm-inlineChangedLine": { backgroundColor: "var(--heed-added-line)" },
    "&.cm-merge-a .cm-changedText, .cm-deletedChunk .cm-deletedText": {
      background: "var(--heed-deleted-text)",
    },
    "&.cm-merge-b .cm-changedText": { background: "var(--heed-added-text)" },
    "&.cm-merge-a .cm-changedLineGutter, .cm-deletedLineGutter": { background: "var(--heed-deleted)" },
    "&.cm-merge-b .cm-changedLineGutter": { background: "var(--heed-added)" },
    ".cm-changeGutter": { width: "3px", paddingLeft: "0" },
    ".cm-collapsedLines": {
      color: "var(--heed-muted)",
      background: "var(--heed-bg2)",
      borderTop: "1px solid var(--heed-line)",
      borderBottom: "1px solid var(--heed-line)",
      fontFamily: "var(--heed-ui-font)",
      fontSize: "11.5px",
      padding: "4px 14px",
    },
    ".cm-collapsedLines:hover": { color: "var(--heed-fg)", background: "var(--heed-bg3)" },
    ".cm-heed-current": { boxShadow: "inset 2px 0 0 var(--heed-current)" },
    ".cm-deletedChunk": { paddingLeft: "0" },
  },
  { dark: true },
);

// The hunk you are on, marked with a bar at its left edge.
const setCurrent = StateEffect.define<{ from: number; to: number } | null>();
const currentField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(marks, tr) {
    marks = marks.map(tr.changes);
    for (const effect of tr.effects) {
      if (!effect.is(setCurrent)) continue;
      if (!effect.value) {
        marks = Decoration.none;
        continue;
      }
      const doc = tr.state.doc;
      const first = doc.lineAt(Math.min(effect.value.from, doc.length)).number;
      const last = doc.lineAt(Math.min(Math.max(effect.value.to - 1, effect.value.from), doc.length)).number;
      const line = Decoration.line({ class: "cm-heed-current" });
      const ranges = [];
      for (let n = first; n <= last; n++) ranges.push(line.range(doc.line(n).from));
      marks = Decoration.set(ranges);
    }
    return marks;
  },
  provide: (field) => EditorView.decorations.from(field),
});

const root = document.getElementById("diff") as HTMLElement;
let payload: Payload | null = null;
let merge: MergeView | null = null;
let unified: EditorView | null = null;
let target: Target | null = null;

const collapse = { margin: 3, minSize: 4 };
const diffConfig = { scanLimit: 500, timeout: 1000 };

function editorExtensions(language: string | null, side: "a" | "b"): Extension[] {
  const support = language ? languages[language]?.() : undefined;
  return [
    lineNumbers(),
    highlightSpecialChars(),
    syntaxHighlighting(syntax),
    theme,
    EditorState.readOnly.of(true),
    EditorView.editable.of(false),
    currentField,
    EditorView.updateListener.of((update) => {
      if (!update.selectionSet || !update.transactions.some((tr) => tr.isUserEvent("select"))) return;
      clicked(update.view, side);
    }),
    support ?? [],
  ];
}

/** The scrolling element: the merge view itself, or the unified editor's scroller. */
function scroller(): HTMLElement | null {
  return merge?.dom ?? unified?.scrollDOM ?? null;
}

/** The editor that shows the new file (side b), where hunks are counted and lines mean the working file. */
function mainView(): EditorView | null {
  return merge?.b ?? unified;
}

function chunks(): readonly Chunk[] {
  if (merge) return merge.chunks;
  const view = unified;
  return view ? (getChunks(view.state)?.chunks ?? []) : [];
}

function destroy(): void {
  merge?.destroy();
  unified?.destroy();
  merge = null;
  unified = null;
  root.textContent = "";
}

function render(next: Payload): void {
  const keep = next.keepScroll && payload?.path === next.path ? (scroller()?.scrollTop ?? 0) : null;
  const kept = keep !== null ? target : null;
  destroy();
  payload = next;
  target = null;
  if (next.mode === "split") {
    merge = new MergeView({
      a: { doc: next.old, extensions: editorExtensions(next.language, "a") },
      b: { doc: next.new, extensions: editorExtensions(next.language, "b") },
      parent: root,
      highlightChanges: true,
      gutter: true,
      collapseUnchanged: collapse,
      diffConfig,
    });
    merge.dom.style.height = "100%";
  } else {
    unified = new EditorView({
      parent: root,
      state: EditorState.create({
        doc: next.new,
        extensions: [
          editorExtensions(next.language, "b"),
          unifiedMergeView({
            original: next.old,
            highlightChanges: true,
            gutter: true,
            mergeControls: false,
            syntaxHighlightDeletions: true,
            collapseUnchanged: collapse,
            diffConfig,
          }),
        ],
      }),
    });
  }
  const scrolling = scroller();
  scrolling?.addEventListener("scroll", scrolled, { passive: true });
  requestAnimationFrame(() => {
    if (keep !== null && scrolling) {
      scrolling.scrollTop = keep;
      if (kept && kept.chunk < chunks().length) mark(kept.chunk, false, kept);
    } else if (next.focus === "first" && chunks().length) {
      mark(0, true);
    } else if (next.focus === "last" && chunks().length) {
      mark(chunks().length - 1, true);
    }
    report();
    post({ type: "shown", path: next.path, hunks: chunks().length });
  });
}

/** Marks chunk `index` as the one you are on (scrolling it to the middle when `scroll`). */
function mark(index: number, scroll: boolean, from?: Target): void {
  const list = chunks();
  const chunk = list[index];
  if (!chunk) return;
  target = from ?? { chunk: index };
  const views = merge ? [merge.a, merge.b] : unified ? [unified] : [];
  for (const view of views) {
    const isA = merge !== null && view === merge.a;
    const range = isA ? { from: chunk.fromA, to: chunk.toA } : { from: chunk.fromB, to: chunk.toB };
    const effects: StateEffect<unknown>[] = [setCurrent.of(range)];
    if (scroll && !isA) {
      effects.push(EditorView.scrollIntoView(Math.min(chunk.fromB, view.state.doc.length), { y: "center" }));
    }
    view.dispatch({ effects });
  }
  report();
}

/** A click (or a selection) in a side: that line is what `a`, `y` and `e` use. */
function clicked(view: EditorView, side: "a" | "b"): void {
  const head = view.state.selection.main.head;
  const line = view.state.doc.lineAt(head).number;
  const list = chunks();
  let index = list.findIndex((chunk) =>
    side === "a" ? head >= chunk.fromA && head <= chunk.toA : head >= chunk.fromB && head <= chunk.toB,
  );
  if (index < 0) index = Math.max(0, nearest(list, head, side));
  target = { chunk: index, line, side };
  report();
}

function nearest(list: readonly Chunk[], pos: number, side: "a" | "b"): number {
  let found = -1;
  list.forEach((chunk, index) => {
    if ((side === "a" ? chunk.fromA : chunk.fromB) <= pos) found = index;
  });
  return found;
}

/** Where chunk `index` starts on screen, relative to the scroller's top. */
function chunkTop(index: number): number | null {
  const view = mainView();
  const chunk = chunks()[index];
  const scrolling = scroller();
  if (!view || !chunk || !scrolling) return null;
  const block = view.lineBlockAt(Math.min(chunk.fromB, view.state.doc.length));
  return view.documentTop + block.top - scrolling.getBoundingClientRect().top;
}

/** The first hunk at or below the top of the view; -1 when none is. */
function firstVisible(): number {
  const scrolling = scroller();
  if (!scrolling) return -1;
  const list = chunks();
  for (let index = 0; index < list.length; index++) {
    const top = chunkTop(index);
    if (top !== null && top >= -4) return top < scrolling.clientHeight ? index : -1;
  }
  return -1;
}

let scrollPending = false;
function scrolled(): void {
  if (scrollPending) return;
  scrollPending = true;
  requestAnimationFrame(() => {
    scrollPending = false;
    // A hunk you went to stays yours while it is on screen; scrolled away, the topmost visible hunk is.
    const scrolling = scroller();
    if (target && scrolling) {
      const top = chunkTop(target.chunk);
      if (top !== null && top > -40 && top < scrolling.clientHeight) return;
      target = null;
    }
    report();
  });
}

function report(): void {
  const view = mainView();
  if (!view || !payload) return;
  const list = chunks();
  const index = target?.chunk ?? firstVisible();
  const chunk = index >= 0 ? list[index] : undefined;
  let line = 1;
  let side: "a" | "b" = "b";
  if (target?.line !== undefined) {
    line = target.line;
    side = target.side ?? "b";
  } else if (chunk) {
    line = view.state.doc.lineAt(Math.min(chunk.fromB, view.state.doc.length)).number;
  }
  post({
    type: "cursor",
    path: payload.path,
    line,
    side,
    hunk: index >= 0 ? index + 1 : 0,
    hunks: list.length,
    scrollTop: scroller()?.scrollTop ?? 0,
  });
}

const api = {
  show(next: Payload): void {
    render(next);
  },

  /** Next (`delta` > 0) or previous hunk; false at either end, so Swift can move to the next file. */
  hunk(delta: number): boolean {
    const list = chunks();
    if (!list.length) return false;
    const from = target?.chunk ?? -1;
    let next: number;
    if (from < 0) {
      const visible = firstVisible();
      next = delta > 0 ? Math.max(visible, 0) : visible > 0 ? visible - 1 : -1;
    } else {
      next = from + delta;
    }
    if (next < 0 || next >= list.length) return false;
    mark(next, true);
    return true;
  },

  setMode(mode: Mode): void {
    if (!payload || payload.mode === mode) return;
    const at = target?.chunk ?? -1;
    render({ ...payload, mode, keepScroll: false, focus: null });
    if (at >= 0) requestAnimationFrame(() => mark(at, true));
  },

  /** ⌃d / ⌃u: half a page down (`fraction` 0.5) or up (-0.5). */
  scrollPage(fraction: number): void {
    const scrolling = scroller();
    if (scrolling) scrolling.scrollBy({ top: scrolling.clientHeight * fraction });
  },

  clear(): void {
    destroy();
    payload = null;
    target = null;
  },
};

window.heedDiff = api;
post({ type: "ready" });
