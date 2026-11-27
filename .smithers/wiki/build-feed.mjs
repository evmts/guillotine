#!/usr/bin/env node
/**
 * Engineering Wiki & Mythical History builder, validator, and Smithers Cloud feed publisher.
 *
 * Usage:
 *   node .smithers/wiki/build-feed.mjs --write   # write feed JSON + docs/public/wiki.html + .smithers/reports/wiki.html
 *   node .smithers/wiki/build-feed.mjs --check   # validate catalog, frontmatter, wikilinks, inputs, leak guard, size bounds
 *   node .smithers/wiki/build-feed.mjs --push    # publish `wiki` feed document to https://smithers.sh/api/repos/evmts/guillotine/feeds
 */
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"

const WIKI_DIR = ".smithers/wiki"
const CATALOG_PATH = join(WIKI_DIR, "coding-project.json")
const FEED_OUT = ".smithers/reports/wiki-feed.json"
const REPORT_HTML_OUT = ".smithers/reports/wiki.html"
const DOCS_HTML_OUT = "docs/public/wiki.html"
const DOCS_CLEAN_HTML_OUT = "docs/public/wiki/index.html"
const MAX_FEED_BYTES = 950_000 // safely under Smithers' 1 MiB document cap

const LEAK_PATTERNS = [
  { name: "smithers-mcp-token", re: /\bsma_[0-9a-f]{32,}\b/ },
  { name: "smithers-attach-token", re: /\bsmat_[A-Za-z0-9_-]{32,}\b/ },
  { name: "smithers-machine-token", re: /\bsmm_[A-Za-z0-9_-]{32,}\b/ },
  { name: "github-pat", re: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/ },
  { name: "private-key", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: "home-path", re: /\/(?:Users|home)\/[A-Za-z0-9._-]+\// }
]

export function parseFrontmatter(source) {
  if (!source.startsWith("---\n") && !source.startsWith("---\r\n")) {
    return { title: undefined, tags: [], body: source }
  }
  const end = source.indexOf("\n---", 3)
  if (end === -1) return { title: undefined, tags: [], body: source }
  const header = source.slice(4, end)
  const body = source.slice(end + 4).replace(/^\r?\n/, "")
  let title
  const tags = []
  for (const rawLine of header.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (line.startsWith("title:")) {
      const value = line.slice("title:".length).trim().replace(/^["']|["']$/g, "")
      if (value !== "") title = value
    } else if (line.startsWith("tags:")) {
      const value = line.slice("tags:".length).trim().replace(/^\[|\]$/g, "")
      for (const tag of value.split(",")) {
        const clean = tag.trim().replace(/^["']|["']$/g, "")
        if (clean !== "") tags.push(clean)
      }
    }
  }
  return { title, tags, body }
}

export function extractWikilinks(markdown) {
  const targets = []
  let fenced = false
  for (const line of markdown.split("\n")) {
    if (/^\s*```/.test(line)) {
      fenced = !fenced
      continue
    }
    if (fenced) continue
    const cleaned = line.replace(/`[^`]*`/g, "")
    const re = /\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]/g
    let m
    while ((m = re.exec(cleaned)) !== null) {
      const target = m[1].trim()
      if (target && !targets.includes(target)) targets.push(target)
    }
  }
  return targets
}

function stemOf(p) {
  return p.split("/").at(-1).replace(/\.md$/i, "")
}

function resolveTarget(target, paths) {
  const lower = target.toLowerCase()
  const withExt = lower.endsWith(".md") ? lower : `${lower}.md`
  return (
    paths.find((p) => p.toLowerCase() === withExt || p.toLowerCase() === lower) ??
    paths.find((p) => stemOf(p).toLowerCase() === lower)
  )
}

export function buildWiki(repoRoot = process.cwd()) {
  const catalogFile = resolve(repoRoot, CATALOG_PATH)
  if (!existsSync(catalogFile)) {
    throw new Error(`Missing wiki catalog: ${CATALOG_PATH}`)
  }
  const catalog = JSON.parse(readFileSync(catalogFile, "utf8"))
  if (!Array.isArray(catalog.pages) || catalog.pages.length === 0) {
    throw new Error("Wiki catalog must declare at least one page")
  }

  const errors = []
  const allPaths = catalog.pages.map((p) => p.path)
  const notes = []

  for (const entry of catalog.pages) {
    const file = resolve(repoRoot, WIKI_DIR, entry.path)
    if (!existsSync(file)) {
      errors.push(`Missing wiki page: ${WIKI_DIR}/${entry.path}`)
      continue
    }
    const raw = readFileSync(file, "utf8")
    if (raw.trim().length < 80) {
      errors.push(`Wiki page too short: ${entry.path}`)
    }
    for (const pat of LEAK_PATTERNS) {
      if (pat.re.test(raw)) {
        errors.push(`Leak guard tripped (${pat.name}) in ${WIKI_DIR}/${entry.path}`)
      }
    }
    for (const inputPath of entry.inputs ?? []) {
      if (!existsSync(resolve(repoRoot, inputPath))) {
        errors.push(`Missing declared source input '${inputPath}' in ${entry.path}`)
      }
    }

    const fm = parseFrontmatter(raw)
    if (!fm.title) {
      errors.push(`Missing YAML frontmatter title in ${entry.path}`)
    }
    const rawLinks = extractWikilinks(fm.body)
    const linksOut = []
    for (const target of rawLinks) {
      const resolved = resolveTarget(target, allPaths)
      if (!resolved) {
        errors.push(`Broken wikilink [[${target}]] in ${entry.path}`)
      } else if (resolved !== entry.path && !linksOut.includes(resolved)) {
        linksOut.push(resolved)
      }
    }

    const digest = createHash("sha256").update(raw).digest("hex").slice(0, 12)
    notes.push({
      path: entry.path,
      title: entry.title ?? fm.title ?? stemOf(entry.path),
      tags: [...new Set([...(entry.tags ?? []), ...fm.tags])],
      inputs: entry.inputs ?? [],
      linksOut,
      digest,
      markdown: raw
    })
  }

  const backlinks = new Map()
  for (const n of notes) backlinks.set(n.path, [])
  for (const n of notes) {
    for (const target of n.linksOut) {
      backlinks.get(target)?.push(n.path)
    }
  }
  const enrichedNotes = notes.map((n) => ({
    ...n,
    backlinks: backlinks.get(n.path) ?? []
  }))

  const feedPayload = {
    set: {
      wiki: {
        visibility: "public",
        body: {
          repository: catalog.repository,
          title: catalog.title,
          notes: enrichedNotes.map(({ path, title, tags, markdown }) => ({
            path,
            title,
            tags,
            markdown
          }))
        }
      }
    }
  }

  const feedBytes = Buffer.byteLength(JSON.stringify(feedPayload), "utf8")
  if (feedBytes > MAX_FEED_BYTES) {
    errors.push(`Wiki feed payload (${feedBytes} bytes) exceeds cap (${MAX_FEED_BYTES} bytes)`)
  }

  return { catalog, notes: enrichedNotes, feedPayload, feedBytes, errors }
}

export function renderWikiHtml(data) {
  const safeJson = JSON.stringify({
    repository: data.catalog.repository,
    title: data.catalog.title,
    description: data.catalog.description,
    notes: data.notes.map((n) => ({
      path: n.path,
      title: n.title,
      tags: n.tags,
      inputs: n.inputs,
      linksOut: n.linksOut,
      backlinks: n.backlinks,
      digest: n.digest,
      body: parseFrontmatter(n.markdown).body
    }))
  }).replace(/</g, "\\u003c")

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Guillotine Engineering Wiki and Mythical History</title>
<style>
:root {
  --bg: #0b0e14;
  --panel: #111622;
  --panel-2: #161d2d;
  --border: #232d42;
  --text: #e6ecf7;
  --muted: #93a1bc;
  --accent: #38bdf8;
  --accent-soft: rgba(56, 189, 248, 0.14);
  --green: #34d399;
  --mono: ui-monospace, SFMono-Regular, "JetBrains Mono", Menlo, monospace;
  --sans: Inter, system-ui, -apple-system, sans-serif;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #f8fafc;
    --panel: #ffffff;
    --panel-2: #f1f5f9;
    --border: #e2e8f0;
    --text: #0f172a;
    --muted: #475569;
    --accent: #0284c7;
    --accent-soft: rgba(2, 132, 199, 0.1);
    --green: #059669;
  }
}
* { box-sizing: border-box }
body { margin: 0; font-family: var(--sans); background: var(--bg); color: var(--text); line-height: 1.65 }
header {
  position: sticky; top: 0; z-index: 10;
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px;
  padding: 12px 20px; background: var(--panel); border-bottom: 1px solid var(--border);
}
.brand { display: flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: -0.01em }
.pill { font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 999px; background: var(--accent-soft); color: var(--accent) }
.nav-links { display: flex; gap: 14px; font-size: 13px }
.nav-links a { color: var(--muted); text-decoration: none }
.nav-links a:hover { color: var(--accent) }
.shell { display: grid; grid-template-columns: 260px minmax(0, 1fr) 250px; min-height: calc(100vh - 54px) }
@media (max-width: 1040px) { .shell { grid-template-columns: 230px minmax(0, 1fr) } .right { display: none } }
@media (max-width: 720px) { .shell { grid-template-columns: 1fr } .left { border-right: 0; border-bottom: 1px solid var(--border) } }
aside { padding: 16px; background: var(--panel); border-right: 1px solid var(--border) }
.right { border-right: 0; border-left: 1px solid var(--border) }
input[type="search"] {
  width: 100%; padding: 8px 10px; border-radius: 8px; border: 1px solid var(--border);
  background: var(--bg); color: var(--text); font: inherit; font-size: 13px; margin-bottom: 12px;
}
.nav-item {
  display: block; width: 100%; text-align: left; border: 0; background: transparent; color: var(--text);
  padding: 8px 10px; border-radius: 8px; cursor: pointer; font: inherit; font-size: 13.5px; margin-bottom: 2px;
}
.nav-item:hover { background: var(--panel-2) }
.nav-item.active { background: var(--accent-soft); color: var(--accent); font-weight: 600 }
.meta-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin: 16px 0 8px }
.tags { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px }
.tag { font-size: 11px; padding: 2px 8px; border-radius: 999px; background: var(--panel-2); color: var(--muted); border: 1px solid var(--border) }
main { padding: clamp(20px, 4vw, 44px); max-width: 900px; width: 100%; margin: 0 auto }
article h1 { margin-top: 0; font-size: clamp(26px, 4vw, 34px); line-height: 1.2; letter-spacing: -0.02em }
article h2 { margin-top: 30px; font-size: 20px; border-bottom: 1px solid var(--border); padding-bottom: 6px }
article h3 { margin-top: 22px; font-size: 16px }
article p, article li { color: var(--text) }
article code { font-family: var(--mono); font-size: 0.88em; background: var(--panel-2); padding: 2px 5px; border-radius: 5px }
article pre { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; overflow-x: auto }
article pre code { background: transparent; padding: 0; font-size: 12.5px; line-height: 1.55 }
article table { width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 13.5px }
article th, article td { padding: 8px 10px; border: 1px solid var(--border); text-align: left }
article th { background: var(--panel-2) }
a.wikilink { color: var(--accent); text-decoration: none; border-bottom: 1px dashed var(--accent); cursor: pointer }
a.wikilink:hover { border-bottom-style: solid }
.side-list { list-style: none; padding: 0; margin: 0; display: grid; gap: 6px; font-size: 13px }
.side-list a, .side-list button { color: var(--muted); text-decoration: none; background: none; border: 0; padding: 0; text-align: left; cursor: pointer; font: inherit }
.side-list a:hover, .side-list button:hover { color: var(--accent) }
.input-file { font-family: var(--mono); font-size: 11.5px; color: var(--muted); word-break: break-all }
</style>
</head>
<body>
<header>
  <div class="brand">
    <span>Guillotine Wiki</span>
    <span class="pill">evmts/guillotine</span>
    <span class="pill">Obsidian-compatible</span>
  </div>
  <nav class="nav-links">
    <a href="https://smithers.sh/evmts/guillotine">Smithers Factory</a>
    <a href="https://smithers.sh/evmts/guillotine/-/wiki">Cloud Wiki</a>
    <a href="./audit.html">Lighthouse Audit</a>
    <a href="./">Docs</a>
    <a href="https://github.com/evmts/guillotine">GitHub</a>
  </nav>
</header>
<div class="shell">
  <aside class="left">
    <input id="q" type="search" placeholder="Search wiki and history…" aria-label="Search wiki notes">
    <div id="nav"></div>
  </aside>
  <main>
    <div id="tags" class="tags"></div>
    <article id="doc"></article>
  </main>
  <aside class="right">
    <div class="meta-label">Outline</div>
    <ul id="outline" class="side-list"></ul>
    <div class="meta-label">Backlinks</div>
    <ul id="backlinks" class="side-list"></ul>
    <div class="meta-label">Grounded Sources</div>
    <ul id="inputs" class="side-list"></ul>
  </aside>
</div>
<script>
const DATA = ${safeJson};
const navEl = document.getElementById("nav");
const docEl = document.getElementById("doc");
const tagsEl = document.getElementById("tags");
const outlineEl = document.getElementById("outline");
const backlinksEl = document.getElementById("backlinks");
const inputsEl = document.getElementById("inputs");
const searchEl = document.getElementById("q");

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function resolveNote(target) {
  const low = target.toLowerCase();
  const withMd = low.endsWith(".md") ? low : low + ".md";
  return DATA.notes.find(n => n.path.toLowerCase() === withMd || n.path.toLowerCase() === low || n.path.replace(/\\.md$/i, "").toLowerCase() === low);
}

function inlineMd(text) {
  let out = esc(text);
  out = out.replace(/\`([^\`]+)\`/g, "<code>$1</code>");
  out = out.replace(/\\[\\[([^\\]|#]+)(?:#[^\\]|]*)?(?:\\|([^\\]]*))?\\]\\]/g, (_, target, alias) => {
    const note = resolveNote(target.trim());
    const label = alias ? alias.trim() : (note ? note.title : target.trim());
    return note ? \`<a class="wikilink" href="#\${encodeURIComponent(note.path)}" data-note="\${esc(note.path)}">\${esc(label)}</a>\` : esc(label);
  });
  out = out.replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>");
  return out;
}

function renderMarkdown(md) {
  const lines = md.split("\\n");
  const html = [];
  const headings = [];
  let inCode = false, codeBuf = [];
  let inList = false, inTable = false, tableRows = [];

  function flushList() { if (inList) { html.push("</ul>"); inList = false; } }
  function flushTable() {
    if (!inTable) return;
    const head = tableRows[0];
    const body = tableRows.slice(2);
    html.push("<table><thead><tr>" + head.map(c => "<th>" + inlineMd(c) + "</th>").join("") + "</tr></thead><tbody>");
    for (const r of body) html.push("<tr>" + r.map(c => "<td>" + inlineMd(c) + "</td>").join("") + "</tr>");
    html.push("</tbody></table>");
    inTable = false; tableRows = [];
  }

  for (const line of lines) {
    if (/^\\s*\`\`\`/.test(line)) {
      flushList(); flushTable();
      if (!inCode) { inCode = true; codeBuf = []; }
      else { html.push("<pre><code>" + esc(codeBuf.join("\\n")) + "</code></pre>"); inCode = false; }
      continue;
    }
    if (inCode) { codeBuf.push(line); continue; }
    if (line.trim().startsWith("|") && line.trim().endsWith("|")) {
      flushList();
      inTable = true;
      tableRows.push(line.trim().slice(1, -1).split("|").map(c => c.trim()));
      continue;
    } else {
      flushTable();
    }
    const hm = line.match(/^(#{1,3})\\s+(.*)$/);
    if (hm) {
      flushList();
      const level = hm[1].length;
      const text = hm[2].trim();
      const id = text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
      if (level >= 2) headings.push({ level, text, id });
      html.push(\`<h\${level} id="\${esc(id)}">\${inlineMd(text)}</h\${level}>\`);
      continue;
    }
    const lm = line.match(/^\\s*[-*]\\s+(.*)$/) || line.match(/^\\s*\\d+\\.\\s+(.*)$/);
    if (lm) {
      if (!inList) { html.push("<ul>"); inList = true; }
      html.push("<li>" + inlineMd(lm[1]) + "</li>");
      continue;
    }
    flushList();
    if (line.trim() === "") continue;
    html.push("<p>" + inlineMd(line) + "</p>");
  }
  flushList(); flushTable();
  return { html: html.join("\\n"), headings };
}

let activePath = DATA.notes[0]?.path ?? "";

function renderNav(filter = "") {
  const q = filter.trim().toLowerCase();
  const visible = DATA.notes.filter(n => !q || n.title.toLowerCase().includes(q) || n.body.toLowerCase().includes(q) || n.tags.some(t => t.toLowerCase().includes(q)));
  navEl.innerHTML = visible.map(n => \`<button class="nav-item \${n.path === activePath ? "active" : ""}" data-note="\${esc(n.path)}">\${esc(n.title)}</button>\`).join("");
  for (const btn of navEl.querySelectorAll("button")) {
    btn.addEventListener("click", () => selectNote(btn.dataset.note));
  }
}

function selectNote(path) {
  const note = DATA.notes.find(n => n.path === path) ?? DATA.notes[0];
  if (!note) return;
  activePath = note.path;
  if (location.hash !== "#" + encodeURIComponent(note.path)) {
    history.replaceState(null, "", "#" + encodeURIComponent(note.path));
  }
  renderNav(searchEl.value);
  tagsEl.innerHTML = note.tags.map(t => \`<span class="tag">#\${esc(t)}</span>\`).join("") + \`<span class="tag">sha:\${esc(note.digest)}</span>\`;
  const rendered = renderMarkdown(note.body);
  docEl.innerHTML = rendered.html;
  for (const a of docEl.querySelectorAll("a.wikilink")) {
    a.addEventListener("click", (e) => { e.preventDefault(); selectNote(a.dataset.note); window.scrollTo(0, 0); });
  }
  outlineEl.innerHTML = rendered.headings.length
    ? rendered.headings.map(h => \`<li style="padding-left:\${(h.level - 2) * 12}px"><a href="#\${esc(h.id)}">\${esc(h.text.replace(/\`/g, ""))}</a></li>\`).join("")
    : '<li class="input-file">No subsections</li>';
  backlinksEl.innerHTML = note.backlinks.length
    ? note.backlinks.map(p => {
        const src = DATA.notes.find(n => n.path === p);
        return \`<li><button data-note="\${esc(p)}">\${esc(src ? src.title : p)}</button></li>\`;
      }).join("")
    : '<li class="input-file">No incoming links</li>';
  for (const btn of backlinksEl.querySelectorAll("button")) {
    btn.addEventListener("click", () => { selectNote(btn.dataset.note); window.scrollTo(0, 0); });
  }
  inputsEl.innerHTML = note.inputs.map(f => \`<li class="input-file" title="\${esc(f)}" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">\${esc(f)}</li>\`).join("");
}

searchEl.addEventListener("input", () => renderNav(searchEl.value));
window.addEventListener("hashchange", () => {
  const target = decodeURIComponent(location.hash.replace(/^#/, ""));
  if (target) selectNote(target);
});

const initial = decodeURIComponent(location.hash.replace(/^#/, ""));
selectNote(initial || "Overview.md");
</script>
</body>
</html>
`
}

async function pushFeed(feedPayload) {
  const key = process.env.SMITHERS_FEED_KEY
  if (!key) {
    throw new Error("SMITHERS_FEED_KEY is required for --push")
  }
  const url = process.env.SMITHERS_FEED_URL ?? "https://smithers.sh/api/repos/evmts/guillotine/feeds"
  const res = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${key}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(feedPayload)
  })
  if (!res.ok) {
    throw new Error(`Feed publish failed with HTTP ${res.status}`)
  }
  const body = await res.json()
  console.log("Published wiki feed:", JSON.stringify(body))
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = new Set(process.argv.slice(2))
  const result = buildWiki(process.cwd())
  if (result.errors.length > 0) {
    for (const err of result.errors) console.error("ERROR:", err)
    process.exit(1)
  }

  if (args.has("--write") || (!args.has("--check") && !args.has("--push"))) {
    for (const outPath of [FEED_OUT, REPORT_HTML_OUT, DOCS_HTML_OUT, DOCS_CLEAN_HTML_OUT]) {
      mkdirSync(dirname(outPath), { recursive: true })
    }
    writeFileSync(FEED_OUT, JSON.stringify(result.feedPayload, null, 2) + "\n")
    const html = renderWikiHtml(result)
    writeFileSync(REPORT_HTML_OUT, html)
    writeFileSync(DOCS_HTML_OUT, html)
    writeFileSync(DOCS_CLEAN_HTML_OUT, html)
  }

  if (args.has("--check")) {
    if (!existsSync(DOCS_HTML_OUT)) {
      console.error(`ERROR: Missing generated wiki viewer ${DOCS_HTML_OUT}; run --write first.`)
      process.exit(1)
    }
  }

  if (args.has("--push")) {
    await pushFeed(result.feedPayload)
  }

  console.log(
    `Wiki ok: ${result.notes.length} pages, ${result.notes.reduce((s, n) => s + n.linksOut.length, 0)} wikilinks, ${result.feedBytes} bytes`
  )
}
