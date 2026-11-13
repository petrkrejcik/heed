/**
 * Heed Note tab renderer.
 *
 * Swift sends: { markdown, path, links, embeds, scroll? }
 *   links:  { "[[target]]raw" -> absolutePath | null }
 *   embeds: { "target" -> { markdown?: string, imageURL?: string } }
 *   scroll?: number (0-1 fraction to restore)
 *
 * JS posts back (via window.webkit.messageHandlers.heed.postMessage):
 *   { type: "ready" }
 *   { type: "shown" }
 *   { type: "link", target: string, url?: string, newTab: boolean }  — wikilink or web link clicked
 */

import MarkdownIt from "markdown-it";
import footnotePlugin from "markdown-it-footnote";
import hljs from "highlight.js/lib/core";

// Register only the languages we care about to keep the bundle small.
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
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("ts", typescript);
hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("js", javascript);
hljs.registerLanguage("json", json);
hljs.registerLanguage("bash", bash);
hljs.registerLanguage("shell", bash);
hljs.registerLanguage("yaml", yaml);
hljs.registerLanguage("swift", swift);
hljs.registerLanguage("python", python);
hljs.registerLanguage("css", css);
hljs.registerLanguage("markdown", markdownLang);
hljs.registerLanguage("diff", diff);

// ── Types ──────────────────────────────────────────────────────────────────

interface NotePayload {
  markdown: string;
  path: string;
  /** resolved: target -> absolute path or null */
  links: Record<string, string | null>;
  /** embeds: target -> { markdown?: string; imageURL?: string } */
  embeds: Record<string, { markdown?: string; imageURL?: string }>;
  /** 0-1 scroll fraction to restore */
  scroll?: number;
}

// ── webkit bridge ──────────────────────────────────────────────────────────

function post(msg: object) {
  (window as any).webkit?.messageHandlers?.heed?.postMessage(msg);
}

// ── markdown-it setup ──────────────────────────────────────────────────────

const md: MarkdownIt = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: false,
  highlight(code: string, lang: string): string {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return (
          '<pre class="hljs"><code>' +
          hljs.highlight(code, { language: lang, ignoreIllegals: true }).value +
          "</code></pre>"
        );
      } catch {}
    }
    return (
      '<pre class="hljs"><code>' +
      md.utils.escapeHtml(code) +
      "</code></pre>"
    );
  },
});

md.use(footnotePlugin);

// ── Custom plugins ─────────────────────────────────────────────────────────

/** ==highlight== → <mark> */
md.core.ruler.push("obsidian_highlight", (state) => {
  for (const token of state.tokens) {
    if (token.type === "inline" && token.children) {
      token.children = processInlineTokens(token.children);
    }
  }
});

function processInlineTokens(tokens: any[]): any[] {
  const result: any[] = [];
  let i = 0;
  while (i < tokens.length) {
    const tok = tokens[i];
    if (tok.type === "text") {
      let content = tok.content as string;
      // Hide Obsidian comments: %%...%%
      content = content.replace(/%%[^%]*%%/g, "");
      // ==highlight== → <mark>
      content = content.replace(/==(.*?)==/g, "<mark>$1</mark>");
      // #tag (at word boundary, not inside code)
      content = content.replace(
        /(?<!\w)#([a-zA-Z][a-zA-Z0-9_/-]*)/g,
        '<span class="heed-tag">#$1</span>'
      );
      tok.content = content;
    }
    result.push(tok);
    i++;
  }
  return result;
}

/** Wikilinks: [[target]], [[target|alias]], [[target#heading]] */
function wikilinkPlugin(md: MarkdownIt, links: Record<string, string | null>) {
  md.core.ruler.after("obsidian_highlight", "wikilinks", (state) => {
    for (const token of state.tokens) {
      if (token.type === "inline" && token.children) {
        token.children = expandWikilinks(token.children, links);
      }
    }
  });
}

function expandWikilinks(
  tokens: any[],
  links: Record<string, string | null>
): any[] {
  const result: any[] = [];
  for (const tok of tokens) {
    if (tok.type !== "text") {
      result.push(tok);
      continue;
    }
    const text = tok.content as string;
    const parts = splitByWikilinks(text);
    for (const part of parts) {
      if (part.type === "text") {
        const t = Object.assign({}, tok);
        t.content = part.value;
        result.push(t);
      } else {
        // wikilink
        const raw = part.raw!;
        const target = part.target!;
        const alias = part.alias || target;
        const resolved = links[raw];
        const tokenOpen = newToken("html_inline", "");
        if (resolved !== null && resolved !== undefined) {
          tokenOpen.content = `<a href="#" class="heed-wikilink" data-target="${escAttr(raw)}" data-path="${escAttr(resolved || "")}">${escHtml(alias)}</a>`;
        } else {
          tokenOpen.content = `<span class="heed-wikilink-unresolved" data-target="${escAttr(raw)}">${escHtml(alias)}</span>`;
        }
        result.push(tokenOpen);
      }
    }
  }
  return result;
}

interface TextPart {
  type: "text" | "wikilink";
  value: string;
  raw?: string;
  target?: string;
  alias?: string;
}

function splitByWikilinks(text: string): TextPart[] {
  const parts: TextPart[] = [];
  let last = 0;
  const re = /\[\[([^\]\n]+)\]\]/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) parts.push({ type: "text", value: text.slice(last, m.index) });
    const inner = m[1];
    const raw = inner;
    // Strip heading and alias.
    let target = inner;
    let alias: string | undefined;
    if (target.includes("|")) {
      const idx = target.lastIndexOf("|");
      alias = target.slice(idx + 1);
      target = target.slice(0, idx);
    }
    if (target.includes("#")) target = target.slice(0, target.indexOf("#"));
    parts.push({ type: "wikilink", value: "", raw, target, alias: alias || target });
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push({ type: "text", value: text.slice(last) });
  return parts;
}

/** Obsidian callouts: > [!type] Title */
function calloutPlugin(md: MarkdownIt) {
  const origBlockquote = md.renderer.rules.blockquote_open!;
  md.core.ruler.after("wikilinks", "callouts", (state) => {
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== "blockquote_open") continue;
      // Find the first inline token inside.
      let j = i + 1;
      while (j < tokens.length && tokens[j].type !== "blockquote_close") {
        if (tokens[j].type === "inline") {
          const content = tokens[j].content;
          const m = content.match(/^\[!([a-zA-Z]+)\]([+-]?)(.*)$/);
          if (m) {
            const type = m[1].toLowerCase();
            const foldable = m[2];
            const title = m[3].trim() || capitalize(type);
            tokens[i].attrSet("class", `heed-callout heed-callout-${type}`);
            tokens[i].attrSet("data-callout", type);
            if (foldable) tokens[i].attrSet("data-foldable", foldable);
            // Replace first inline with just a title element.
            tokens[j].content = "";
            const titleToken = new state.Token("html_block", "", 0);
            titleToken.content = `<div class="heed-callout-title"><span class="heed-callout-icon"></span>${escHtml(title)}</div>`;
            tokens.splice(j, 0, titleToken);
          }
          break;
        }
        j++;
      }
    }
  });
}

/** Task lists: - [ ] / - [x] */
function taskListPlugin(md: MarkdownIt) {
  md.core.ruler.push("task_lists", (state) => {
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type === "bullet_list_open") {
        processListTokens(tokens, i, state);
      }
    }
  });
}

function processListTokens(tokens: any[], listStart: number, state: any) {
  let i = listStart + 1;
  while (i < tokens.length && tokens[i].type !== "bullet_list_close") {
    if (tokens[i].type === "inline") {
      const c = tokens[i].content;
      const checked = c.startsWith("[x] ") || c.startsWith("[X] ");
      const unchecked = c.startsWith("[ ] ");
      if (checked || unchecked) {
        tokens[i].content = c.slice(4);
        const prefix = new state.Token("html_inline", "", 0);
        prefix.content = `<input type="checkbox" disabled${checked ? " checked" : ""} class="heed-task-checkbox"> `;
        if (!tokens[i].children) tokens[i].children = [];
        tokens[i].children!.unshift(prefix);
      }
    }
    i++;
  }
}

/** Frontmatter: parse and render as a properties table. */
function extractFrontmatter(markdown: string): {
  body: string;
  props: Record<string, any>;
} {
  if (!markdown.startsWith("---")) return { body: markdown, props: {} };
  const end = markdown.indexOf("\n---", 4);
  if (end < 0) return { body: markdown, props: {} };
  const yaml = markdown.slice(4, end).trim();
  const body = markdown.slice(end + 4).trimStart();
  const props: Record<string, any> = {};
  let currentKey = "";
  let inList = false;
  for (const line of yaml.split("\n")) {
    const kv = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)/);
    if (kv) {
      currentKey = kv[1];
      const val = kv[2].trim();
      if (val === "" || val === null) {
        inList = true;
        props[currentKey] = [];
      } else if (val.startsWith("[")) {
        inList = false;
        props[currentKey] = val
          .slice(1, val.lastIndexOf("]"))
          .split(",")
          .map((s) => s.trim().replace(/^["']|["']$/g, ""))
          .filter(Boolean);
      } else {
        inList = false;
        props[currentKey] = val.replace(/^["']|["']$/g, "");
      }
    } else if (inList && line.trim().startsWith("- ")) {
      (props[currentKey] as string[]).push(line.trim().slice(2));
    }
  }
  return { body, props };
}

function renderFrontmatter(
  props: Record<string, any>,
  links: Record<string, string | null>
): string {
  const skipped = new Set(["type", "task_id"]);
  const entries = Object.entries(props).filter(([k]) => !skipped.has(k));
  if (entries.length === 0) return "";
  let html = '<div class="heed-properties">\n';
  for (const [key, value] of entries) {
    const label = key.replace(/_/g, " ");
    const values = Array.isArray(value) ? value : [value];
    const rendered = values
      .map((v) => {
        const s = String(v);
        // Render wikilinks inside property values.
        const wikilinkMatch = s.match(/^\[\[([^\]]+)\]\]$/) || s.match(/^\[\[([^\]]+)\]\]$/);
        if (wikilinkMatch) {
          const raw = wikilinkMatch[1];
          const resolved = links[raw];
          if (resolved) {
            return `<a href="#" class="heed-wikilink" data-target="${escAttr(raw)}" data-path="${escAttr(resolved)}">${escHtml(raw.includes("|") ? raw.slice(raw.lastIndexOf("|") + 1) : raw)}</a>`;
          }
          return `<span class="heed-wikilink-unresolved">${escHtml(raw)}</span>`;
        }
        return escHtml(s);
      })
      .join(", ");
    html += `  <div class="heed-property"><span class="heed-property-key">${escHtml(label)}</span><span class="heed-property-value">${rendered}</span></div>\n`;
  }
  html += "</div>\n";
  return html;
}

// ── Utilities ──────────────────────────────────────────────────────────────

function newToken(type: string, tag: string): any {
  return { type, tag, attrs: null, map: null, level: 0, children: null, content: "", markup: "", info: "", meta: null, block: false, hidden: false };
}

function escAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

function escHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// ── Mermaid lazy loading ───────────────────────────────────────────────────

let mermaidLoaded = false;

async function loadMermaid(): Promise<void> {
  if (mermaidLoaded) return;
  mermaidLoaded = true;
  return new Promise((resolve) => {
    const script = document.createElement("script");
    // mermaid.js lives next to note.js in the bundle folder.
    script.src = "mermaid.js";
    script.onload = () => {
      (window as any).mermaid?.initialize({
        startOnLoad: false,
        theme: "dark",
        securityLevel: "loose",
      });
      resolve();
    };
    script.onerror = () => resolve();
    document.head.appendChild(script);
  });
}

async function renderMermaid() {
  const pre = Array.from(document.querySelectorAll("pre.hljs code.language-mermaid")).concat(
    Array.from(document.querySelectorAll("pre code.language-mermaid"))
  ) as HTMLElement[];
  if (pre.length === 0) return;
  await loadMermaid();
  const mermaid = (window as any).mermaid;
  if (!mermaid) return;
  for (const el of pre) {
    const container = document.createElement("div");
    container.className = "heed-mermaid";
    container.textContent = el.textContent || "";
    el.closest("pre")?.replaceWith(container);
  }
  try {
    await mermaid.run({ nodes: document.querySelectorAll(".heed-mermaid") });
  } catch {}
}

// ── Main renderer ──────────────────────────────────────────────────────────

function render(payload: NotePayload) {
  const { body, props } = extractFrontmatter(payload.markdown);

  // Register plugins with current links map.
  // Re-register each render to pick up fresh link resolutions.
  const mdLocal = md;
  // We re-use the same md instance; wikilink plugin reads closure-captured links.
  const links = payload.links;
  const linksForWikilinks: Record<string, string | null> = {};
  for (const [raw, resolved] of Object.entries(links)) {
    linksForWikilinks[raw] = resolved;
  }

  // Apply plugins if not already registered.
  if (!(md as any).__heedPluginsApplied) {
    (md as any).__heedPluginsApplied = true;
    md.use(calloutPlugin);
    md.use(taskListPlugin);
    md.use((md: MarkdownIt) => wikilinkPlugin(md, linksForWikilinks));
  } else {
    // Update the links map in place (the plugin captures the reference).
    for (const k of Object.keys(linksForWikilinks)) {
      (md as any).__heedLinks[k] = linksForWikilinks[k];
    }
  }
  (md as any).__heedLinks = linksForWikilinks;

  const propsHtml = renderFrontmatter(props, payload.links);
  const bodyHtml = md.render(body);

  const content = document.getElementById("content")!;
  content.innerHTML = propsHtml + bodyHtml;

  // Render embeds: replace ![[target]] spans with actual content.
  for (const [target, embed] of Object.entries(payload.embeds)) {
    const sel = `[data-embed="${CSS.escape(target)}"]`;
    document.querySelectorAll(sel).forEach((el) => {
      if (embed.imageURL) {
        el.outerHTML = `<img src="${escAttr(embed.imageURL)}" class="heed-embed-image" alt="${escAttr(target)}">`;
      } else if (embed.markdown) {
        el.outerHTML = `<div class="heed-embed">${md.render(embed.markdown)}</div>`;
      }
    });
  }

  renderMermaid();
}

// ── Scroll helpers ─────────────────────────────────────────────────────────

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

// ── Click handling ─────────────────────────────────────────────────────────

document.addEventListener("click", (e) => {
  const target = e.target as HTMLElement;
  const link = target.closest("a");
  if (!link) return;
  e.preventDefault();

  const newTab = e.metaKey;

  if (link.classList.contains("heed-wikilink")) {
    const raw = link.dataset.target || "";
    const path = link.dataset.path || "";
    post({ type: "link", target: raw, path, newTab });
    return;
  }

  const href = link.getAttribute("href") || "";
  if (href && href !== "#") {
    post({ type: "link", url: href, newTab });
  }
});

// ── Public API (called by Swift via callAsyncJavaScript) ───────────────────

(window as any).heedNote = {
  show(payload: NotePayload) {
    render(payload);
    if (payload.scroll !== undefined && payload.scroll !== null) {
      const max =
        document.documentElement.scrollHeight - document.documentElement.clientHeight;
      document.documentElement.scrollTop = Math.round(payload.scroll * max);
    }
    post({ type: "shown" });
  },
  scrollPage,
  scrollEdge,
  getScroll,
  reload() {
    post({ type: "reload" });
  },
};

// ── Bootstrap ─────────────────────────────────────────────────────────────

document.addEventListener("DOMContentLoaded", () => {
  post({ type: "ready" });
});
