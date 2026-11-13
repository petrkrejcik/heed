/**
 * Heed Note tab renderer.
 *
 * Swift sends: { markdown, path, links, embeds, scroll? }
 *   links:  { "<inside of [[…]]>" -> absolutePath | null }
 *   embeds: { "<inside of ![[…]]>" -> { markdown?: string, imageURL?: string } }
 *   scroll?: number (0-1 fraction to restore)
 *
 * JS posts back (via window.webkit.messageHandlers.heed.postMessage):
 *   { type: "ready" }
 *   { type: "shown" }
 *   { type: "link", target, path, newTab }  a wikilink clicked
 *   { type: "link", url, newTab }           a web link clicked
 */

import MarkdownIt from "markdown-it";
import type StateCore from "markdown-it/lib/rules_core/state_core.mjs";
import type StateInline from "markdown-it/lib/rules_inline/state_inline.mjs";
import type Token from "markdown-it/lib/token.mjs";
import footnotePlugin from "markdown-it-footnote";
import markPlugin from "markdown-it-mark";
import hljs from "highlight.js/lib/core";

import typescript from "highlight.js/lib/languages/typescript";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import bash from "highlight.js/lib/languages/bash";
import yaml from "highlight.js/lib/languages/yaml";
import swift from "highlight.js/lib/languages/swift";
import python from "highlight.js/lib/languages/python";
import css from "highlight.js/lib/languages/css";
import markdownLang from "highlight.js/lib/languages/markdown";
import diff from "highlight.js/lib/languages/diff";
for (const [name, lang] of [
  ["typescript", typescript], ["ts", typescript], ["tsx", typescript],
  ["javascript", javascript], ["js", javascript], ["jsx", javascript],
  ["json", json], ["bash", bash], ["sh", bash], ["shell", bash], ["zsh", bash],
  ["yaml", yaml], ["yml", yaml], ["swift", swift], ["python", python], ["py", python],
  ["css", css], ["scss", css], ["markdown", markdownLang], ["md", markdownLang], ["diff", diff],
] as const) {
  hljs.registerLanguage(name, lang);
}

interface Embed {
  markdown?: string;
  imageURL?: string;
}

interface NotePayload {
  markdown: string;
  path: string;
  links: Record<string, string | null>;
  embeds: Record<string, Embed>;
  scroll?: number;
}

function post(msg: object) {
  (window as any).webkit?.messageHandlers?.heed?.postMessage(msg);
}

// The note being rendered: the inline rules read its links and embeds.
let current: NotePayload = { markdown: "", path: "", links: {}, embeds: {} };
let embedDepth = 0;

const md: MarkdownIt = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: false,
  highlight(code: string, lang: string): string {
    const name = (lang || "").toLowerCase();
    if (name === "mermaid") {
      return `<pre class="heed-mermaid-source">${md.utils.escapeHtml(code)}</pre>`;
    }
    const body = hljs.getLanguage(name)
      ? hljs.highlight(code, { language: name, ignoreIllegals: true }).value
      : md.utils.escapeHtml(code);
    return `<pre class="hljs"><code>${body}</code></pre>`;
  },
});

md.use(footnotePlugin);
md.use(markPlugin);
md.inline.ruler.before("link", "wikilink", wikilinkRule);
md.inline.ruler.before("link", "tag", tagRule);
md.core.ruler.push("callouts", calloutRule);
md.core.ruler.push("task_lists", taskListRule);

// ── Wikilinks and embeds: [[target#heading|alias]], ![[target]] ─────────────

function wikilinkRule(state: StateInline, silent: boolean): boolean {
  const src = state.src;
  let pos = state.pos;
  const embed = src.charCodeAt(pos) === 0x21 /* ! */;
  if (embed) pos++;
  if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b) return false;
  const end = src.indexOf("]]", pos + 2);
  if (end < 0) return false;
  const raw = src.slice(pos + 2, end);
  if (!raw || raw.includes("\n") || raw.includes("[")) return false;
  if (!silent) {
    const token = state.push("html_inline", "", 0);
    token.content = embed ? renderEmbed(raw) : renderWikilink(raw);
  }
  state.pos = end + 2;
  return true;
}

function linkLabel(raw: string): string {
  const pipe = raw.lastIndexOf("|");
  if (pipe >= 0) return raw.slice(pipe + 1);
  const [target, heading] = raw.split("#", 2);
  if (heading === undefined) return target;
  return target ? `${target} › ${heading}` : heading;
}

function renderWikilink(raw: string): string {
  const resolved = current.links[raw];
  const label = escHtml(linkLabel(raw));
  if (resolved) {
    return `<a href="#" class="heed-wikilink" data-target="${escAttr(raw)}" data-path="${escAttr(resolved)}">${label}</a>`;
  }
  return `<span class="heed-wikilink-unresolved" title="No note with this name">${label}</span>`;
}

function renderEmbed(raw: string): string {
  const embed = current.embeds[raw];
  const target = raw.split("|")[0];
  if (embed?.imageURL) {
    const width = raw.includes("|") ? Number(raw.slice(raw.lastIndexOf("|") + 1)) : NaN;
    const size = Number.isFinite(width) && width > 0 ? ` width="${width}"` : "";
    return `<img src="${escAttr(embed.imageURL)}" class="heed-embed-image" alt="${escAttr(target)}"${size}>`;
  }
  if (embed?.markdown !== undefined && embedDepth === 0) {
    embedDepth++;
    try {
      const { body } = extractFrontmatter(embed.markdown);
      embedded.push(md.render(body));
      return `<span class="heed-embed-slot" data-index="${embedded.length - 1}"></span>`;
    } finally {
      embedDepth--;
    }
  }
  return renderWikilink(target);
}

// Embedded notes are blocks; markdown puts them inside a paragraph, so they go in after the HTML is parsed.
let embedded: string[] = [];

function placeEmbeds(root: HTMLElement) {
  root.querySelectorAll<HTMLElement>("span.heed-embed-slot").forEach((slot) => {
    const block = document.createElement("div");
    block.className = "heed-embed";
    block.innerHTML = embedded[Number(slot.dataset.index)] ?? "";
    const paragraph = slot.parentElement;
    if (paragraph?.tagName === "P" && paragraph.childNodes.length === 1) paragraph.replaceWith(block);
    else slot.replaceWith(block);
  });
}

// ── #tags ──────────────────────────────────────────────────────────────────

const tagChar = /[\p{L}\p{N}_\/-]/u;

function tagRule(state: StateInline, silent: boolean): boolean {
  const src = state.src;
  const start = state.pos;
  if (src.charCodeAt(start) !== 0x23 /* # */) return false;
  if (start > 0 && !/\s|[(\[,]/.test(src[start - 1])) return false;
  let end = start + 1;
  while (end < src.length && tagChar.test(src[end])) end++;
  const name = src.slice(start + 1, end);
  if (!name || /^\d+$/.test(name)) return false;
  if (!silent) {
    const token = state.push("html_inline", "", 0);
    token.content = `<span class="heed-tag">#${escHtml(name)}</span>`;
  }
  state.pos = end;
  return true;
}

// ── Callouts: > [!type]± Title ──────────────────────────────────────────────

const calloutMarker = /^\[!([\w-]+)\]([+-]?)[ \t]*/;

function calloutRule(state: StateCore) {
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    const open = tokens[i];
    if (open.type !== "blockquote_open") continue;
    const inline = tokens[i + 2];
    if (tokens[i + 1]?.type !== "paragraph_open" || inline?.type !== "inline") continue;
    const first = inline.children?.[0];
    const marker = first?.type === "text" ? first.content.match(calloutMarker) : null;
    if (!first || !marker) continue;

    const type = marker[1].toLowerCase();
    const fold = marker[2];
    first.content = first.content.slice(marker[0].length);

    // The title is the rest of the first line; the body starts after its line break.
    const children = inline.children!;
    const breakAt = children.findIndex((t) => t.type === "softbreak" || t.type === "hardbreak");
    const titleChildren = breakAt < 0 ? children : children.slice(0, breakAt);
    const bodyChildren = breakAt < 0 ? [] : children.slice(breakAt + 1);
    const titleEmpty = titleChildren.every((t) => t.type === "text" && !t.content.trim());

    const title = new state.Token("inline", "", 0);
    title.children = titleEmpty ? [textToken(state, capitalize(type))] : titleChildren;
    title.content = "";

    const close = findClose(tokens, i);
    const tag = fold ? "details" : "div";
    open.tag = tag;
    tokens[close].tag = tag;
    open.attrSet("class", `heed-callout heed-callout-${type}`);
    open.attrSet("data-callout", type);
    if (fold === "+") open.attrSet("open", "");

    const titleTag = fold ? "summary" : "div";
    const before = [
      html(state, `<${titleTag} class="heed-callout-title"><span class="heed-callout-icon"></span>`),
      title,
      html(state, `</${titleTag}><div class="heed-callout-content">`),
    ];
    if (bodyChildren.length) {
      inline.children = bodyChildren;
    } else {
      // The first paragraph was only the title: drop it.
      tokens.splice(i + 1, 3);
    }
    tokens.splice(i + 1, 0, ...before);
    const newClose = findClose(tokens, i);
    tokens.splice(newClose, 0, html(state, "</div>"));
  }
}

function findClose(tokens: Token[], openIndex: number): number {
  let depth = 0;
  for (let j = openIndex; j < tokens.length; j++) {
    if (tokens[j].type === "blockquote_open") depth++;
    if (tokens[j].type === "blockquote_close" && --depth === 0) return j;
  }
  return tokens.length - 1;
}

// ── Task lists: - [ ] / - [x] ───────────────────────────────────────────────

const taskMarker = /^\[([ xX])\][ \t]/;

function taskListRule(state: StateCore) {
  const tokens = state.tokens;
  for (let i = 2; i < tokens.length; i++) {
    const inline = tokens[i];
    if (inline.type !== "inline" || tokens[i - 1].type !== "paragraph_open" || tokens[i - 2].type !== "list_item_open") {
      continue;
    }
    const first = inline.children?.[0];
    const marker = first?.type === "text" ? first.content.match(taskMarker) : null;
    if (!first || !marker) continue;
    first.content = first.content.slice(marker[0].length);
    const checked = marker[1] !== " ";
    inline.children!.unshift(
      html(state, `<input type="checkbox" disabled${checked ? " checked" : ""} class="heed-task-checkbox">`)
    );
    tokens[i - 2].attrSet("class", checked ? "heed-task heed-task-done" : "heed-task");
    for (let j = i - 3; j >= 0; j--) {
      const t = tokens[j];
      if ((t.type === "bullet_list_open" || t.type === "ordered_list_open") && t.level === tokens[i - 2].level - 1) {
        t.attrSet("class", "heed-task-list");
        break;
      }
    }
  }
}

function html(state: StateCore, content: string): Token {
  const token = new state.Token("html_inline", "", 0);
  token.content = content;
  return token;
}

function textToken(state: StateCore, content: string): Token {
  const token = new state.Token("text", "", 0);
  token.content = content;
  return token;
}

// ── Frontmatter as properties ───────────────────────────────────────────────

function extractFrontmatter(markdown: string): { body: string; props: [string, string[]][] } {
  const match = markdown.match(/^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/);
  if (!match) return { body: markdown, props: [] };
  const props: [string, string[]][] = [];
  for (const line of match[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z_][\w -]*):\s*(.*)$/);
    if (kv) {
      const value = kv[2].trim();
      if (!value) props.push([kv[1], []]);
      else if (value.startsWith("[") && value.endsWith("]") && !value.startsWith("[[")) {
        props.push([kv[1], value.slice(1, -1).split(",").map(unquote).filter(Boolean)]);
      } else props.push([kv[1], [unquote(value)]]);
    } else if (props.length && /^\s+-\s+/.test(line)) {
      props[props.length - 1][1].push(unquote(line.replace(/^\s+-\s+/, "")));
    }
  }
  return { body: markdown.slice(match[0].length), props };
}

function unquote(s: string): string {
  return s.trim().replace(/^(["'])(.*)\1$/, "$2");
}

const hiddenProperties = new Set(["type", "task_id"]);

function renderProperties(props: [string, string[]][]): string {
  const rows = props.filter(([key, values]) => !hiddenProperties.has(key) && values.length);
  if (!rows.length) return "";
  const items = rows.map(([key, values]) => {
    const rendered = values.map((value) => {
      if (key === "tags") return `<span class="heed-tag">#${escHtml(value.replace(/^#/, ""))}</span>`;
      const wikilink = value.match(/^\[\[([^\]]+)\]\]$/);
      if (wikilink) return renderWikilink(wikilink[1]);
      if (/^https?:\/\//.test(value)) return `<a href="${escAttr(value)}">${escHtml(value)}</a>`;
      return escHtml(value);
    });
    const separator = key === "tags" ? " " : ", ";
    return `<div class="heed-property"><span class="heed-property-key">${escHtml(key.replace(/_/g, " "))}</span><span class="heed-property-value">${rendered.join(separator)}</span></div>`;
  });
  return `<div class="heed-properties">${items.join("")}</div>`;
}

// ── Mermaid, loaded only when a note has a diagram ──────────────────────────

let mermaidLoading: Promise<any> | null = null;

function loadMermaid(): Promise<any> {
  mermaidLoading ??= new Promise((resolve) => {
    const script = document.createElement("script");
    script.src = "mermaid.js";
    script.onload = () => {
      const mermaid = (window as any).mermaid;
      mermaid?.initialize({ startOnLoad: false, theme: "dark", securityLevel: "strict" });
      resolve(mermaid);
    };
    script.onerror = () => resolve(null);
    document.head.appendChild(script);
  });
  return mermaidLoading;
}

async function renderMermaid(): Promise<void> {
  const sources = Array.from(document.querySelectorAll<HTMLElement>("pre.heed-mermaid-source"));
  if (!sources.length) return;
  const mermaid = await loadMermaid();
  if (!mermaid) return;
  for (const [index, source] of sources.entries()) {
    try {
      const { svg } = await mermaid.render(`heed-mermaid-${Date.now()}-${index}`, source.textContent || "");
      const figure = document.createElement("div");
      figure.className = "heed-mermaid";
      figure.innerHTML = svg;
      source.replaceWith(figure);
    } catch {
      source.classList.add("heed-mermaid-failed");
    }
  }
}

// ── Rendering ───────────────────────────────────────────────────────────────

function resolveImageSources(root: HTMLElement, notePath: string) {
  const folder = notePath.slice(0, notePath.lastIndexOf("/") + 1);
  root.querySelectorAll<HTMLImageElement>("img:not(.heed-embed-image)").forEach((img) => {
    const src = img.getAttribute("src") || "";
    if (!src || /^[a-z][\w+.-]*:/i.test(src)) return;
    const absolute = src.startsWith("/") ? src : folder + decodeURI(src);
    img.src = "heed-vault://" + encodeURI(absolute);
  });
}

async function render(payload: NotePayload) {
  current = payload;
  const markdown = payload.markdown.replace(/%%[\s\S]*?%%/g, "");
  const { body, props } = extractFrontmatter(markdown);
  const content = document.getElementById("content")!;
  embedded = [];
  content.innerHTML = renderProperties(props) + md.render(body);
  placeEmbeds(content);
  resolveImageSources(content, payload.path);
  await renderMermaid();
}

function scrollPage(fraction: number) {
  const el = document.documentElement;
  el.scrollTop += Math.round(el.clientHeight * fraction);
}

function scrollEdge(top: boolean) {
  document.documentElement.scrollTop = top ? 0 : document.documentElement.scrollHeight;
}

function getScroll(): number {
  const el = document.documentElement;
  const max = el.scrollHeight - el.clientHeight;
  return max > 0 ? el.scrollTop / max : 0;
}

document.addEventListener("click", (e) => {
  const link = (e.target as HTMLElement).closest("a");
  if (!link) return;
  e.preventDefault();
  const newTab = e.metaKey;
  if (link.classList.contains("heed-wikilink")) {
    post({ type: "link", target: link.dataset.target || "", path: link.dataset.path || "", newTab });
    return;
  }
  const href = link.getAttribute("href") || "";
  if (href.startsWith("#fn") || href.startsWith("#fnref")) {
    document.getElementById(href.slice(1))?.scrollIntoView({ block: "center" });
    return;
  }
  if (href && href !== "#") post({ type: "link", url: href, newTab });
});

function escAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

function escHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

(window as any).heedNote = {
  async show(payload: NotePayload) {
    const keep = getScroll();
    await render(payload);
    const fraction = payload.scroll ?? keep;
    const el = document.documentElement;
    el.scrollTop = Math.round(fraction * (el.scrollHeight - el.clientHeight));
    post({ type: "shown" });
  },
  scrollPage,
  scrollEdge,
  getScroll,
};

post({ type: "ready" });
