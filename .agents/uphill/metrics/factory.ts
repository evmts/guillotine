import { Glob } from "bun";
import { createHash } from "crypto";
import { appendFileSync, existsSync, readFileSync } from "fs";
import { basename } from "path";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

function check(metric: string, item: string, ok: boolean, note?: string) {
  lines.push(ok ? `${metric} ${item} pass` : `${metric} ${item} fail note ${q(note ?? "failed")}`);
}

function walkProseStrings(value: unknown, key = "", outList: string[] = []): string[] {
  if (key === "code" || key === "url" || key === "href" || key === "docs") {
    return outList;
  }
  if (typeof value === "string") {
    if (!value.startsWith("http://") && !value.startsWith("https://")) {
      outList.push(value);
    }
  } else if (Array.isArray(value)) {
    for (const entry of value) walkProseStrings(entry, key, outList);
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) walkProseStrings(v, k, outList);
  }
  return outList;
}

// 1. Factory projection (.smithers/factory.json & .smithers/home.json)
{
  const factoryPath = ".smithers/factory.json";
  if (!existsSync(factoryPath)) {
    check("factory-projection", factoryPath, false, "missing .smithers/factory.json");
  } else {
    try {
      const f = JSON.parse(readFileSync(factoryPath, "utf8"));
      const flowsCount = Array.isArray(f.flows) ? f.flows.length : Object.keys(f.flows ?? {}).length;
      const rulesCount = Array.isArray(f.on) ? f.on.length : 0;
      const viewsCount = Array.isArray(f.issueViews) ? f.issueViews.length : 0;
      const approvals = f.policy?.approvals ?? f.policy ?? {};
      const personOnly = approvals.approve === "person" && approvals.merge === "person";
      const ok = f.apiVersion === 1 && flowsCount >= 5 && rulesCount >= 5 && viewsCount >= 3 && personOnly;
      check(
        "factory-projection",
        factoryPath,
        ok,
        ok ? undefined : `apiVersion=${f.apiVersion} flows=${flowsCount} rules=${rulesCount} views=${viewsCount} personOnly=${personOnly}`,
      );
    } catch (err) {
      check("factory-projection", factoryPath, false, `invalid JSON: ${String(err)}`);
    }
  }

  const homePath = ".smithers/home.json";
  if (!existsSync(homePath)) {
    check("factory-projection", homePath, false, "missing .smithers/home.json");
  } else {
    try {
      const h = JSON.parse(readFileSync(homePath, "utf8"));
      const audiences = new Set((h.sections ?? []).map((s: { audience?: string }) => s.audience));
      const proseStrings = walkProseStrings(h);
      const hasForbidden = proseStrings.some((s) => /[;\u2014]/.test(s) || /jjhub/i.test(s) || /<\/?[a-z][^>]*>/i.test(s));
      const hasAllAudiences = audiences.has("maintainer") && audiences.has("contributor") && audiences.has("everyone");
      const ok =
        h.docs === "https://guillotine.tevm.sh/llms.txt" &&
        h.contributors === "role" &&
        hasAllAudiences &&
        !hasForbidden;
      check(
        "factory-projection",
        homePath,
        ok,
        ok
          ? undefined
          : `docs=${h.docs} contributors=${h.contributors} audiences=${[...audiences].join(",")} forbidden=${hasForbidden}`,
      );
    } catch (err) {
      check("factory-projection", homePath, false, `invalid JSON: ${String(err)}`);
    }
  }
}

// 2. Remote cache & execution trust boundary
{
  const wsPath = ".smithers/WORKSPACE.ts";
  if (!existsSync(wsPath)) {
    check("remote-cache-trust", wsPath, false, "missing .smithers/WORKSPACE.ts");
  } else {
    const ws = readFileSync(wsPath, "utf8");
    const ok =
      ws.includes("https://build.smithers.sh") &&
      ws.includes("SMITHERS_CACHE_READ_TOKEN") &&
      ws.includes("SMITHERS_CACHE_WRITE_TOKEN");
    check(
      "remote-cache-trust",
      wsPath,
      ok,
      ok ? undefined : "WORKSPACE.ts must wire https://build.smithers.sh with split read/write secrets",
    );
  }

  const ciPath = ".github/workflows/ci.yml";
  if (!existsSync(ciPath)) {
    check("remote-cache-trust", ciPath, false, "missing .github/workflows/ci.yml");
  } else {
    const ci = readFileSync(ciPath, "utf8");
    const hasRead = ci.includes("SMITHERS_CACHE_READ_TOKEN");
    const hasWrite = ci.includes("SMITHERS_CACHE_WRITE_TOKEN");
    // Ensure write token is strictly gated to trusted pushes on main, never exposed to PRs.
    const writeLines = ci
      .split("\n")
      .filter((l) => l.includes("SMITHERS_CACHE_WRITE_TOKEN") && !l.trim().startsWith("#"));
    const writeProperlyGated =
      writeLines.length > 0 &&
      writeLines.every(
        (l) =>
          (l.includes("github.event_name == 'push'") && l.includes("refs/heads/main")) ||
          l.includes("secrets.SMITHERS_CACHE_WRITE_TOKEN == ''"),
      );
    const ok = hasRead && hasWrite && writeProperlyGated;
    check(
      "remote-cache-trust",
      ciPath,
      ok,
      ok ? undefined : "ci.yml must split cache read/write tokens and gate write token strictly on push to main",
    );
  }
}

// 3. Engineering wiki & mythical history freshness
{
  const cfgPath = ".smithers/wiki/coding-project.json";
  if (!existsSync(cfgPath)) {
    check("wiki-freshness", cfgPath, false, "missing .smithers/wiki/coding-project.json");
  } else {
    try {
      const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
      const pages = [...new Glob(".smithers/wiki/*.md").scanSync(".")].sort();
      const slugs = new Set(pages.map((p) => basename(p, ".md")));
      const okCfg = pages.length >= 6 && slugs.has("Mythical-History") && slugs.has("Overview") && cfg.repository === "evmts/guillotine";
      check("wiki-freshness", cfgPath, okCfg, okCfg ? undefined : `pages=${pages.length} repository=${cfg.repository}`);

      const secretPattern = /(ghp_[A-Za-z0-9]{20,}|smat_[A-Za-z0-9_-]{12,}|sk-[A-Za-z0-9]{20,}|\/Users\/[A-Za-z0-9_.-]+\/)/;
      for (const page of pages) {
        const text = readFileSync(page, "utf8");
        const hasFrontmatter = text.startsWith("---\n") && text.indexOf("\n---\n", 4) > 0;
        const stripped = text.replace(/```[\s\S]*?```/g, "");
        let brokenWiki: string | null = null;
        for (const m of stripped.matchAll(/\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]/g)) {
          const target = m[1]!.trim();
          if (!slugs.has(target)) {
            brokenWiki = `broken wikilink [[${target}]]`;
            break;
          }
        }
        const leak = secretPattern.exec(text);
        const ok = hasFrontmatter && !brokenWiki && !leak;
        check(
          "wiki-freshness",
          page,
          ok,
          !hasFrontmatter
            ? "missing YAML frontmatter"
            : brokenWiki
              ? brokenWiki
              : leak
                ? `forbidden secret or host path pattern: ${leak[0].slice(0, 16)}`
                : undefined,
        );
      }
    } catch (err) {
      check("wiki-freshness", cfgPath, false, `invalid JSON: ${String(err)}`);
    }
  }

  const wikiHtml = "docs/public/wiki.html";
  const hasWikiHtml = existsSync(wikiHtml) && readFileSync(wikiHtml, "utf8").length > 2000;
  check("wiki-freshness", wikiHtml, hasWikiHtml, hasWikiHtml ? undefined : "run node .smithers/wiki/build-feed.mjs --write");
}

// 4. Release & docs automation alignment
{
  const zon = existsSync("build.zig.zon") ? readFileSync("build.zig.zon", "utf8") : "";
  const zonMatch = /\.version\s*=\s*"([^"]+)"/.exec(zon);
  const zonVersion = zonMatch ? zonMatch[1] : null;
  const tsPkg = existsSync("sdks/typescript/package.json")
    ? JSON.parse(readFileSync("sdks/typescript/package.json", "utf8"))
    : null;
  const tsVersion = tsPkg?.version ?? null;
  const changelog = existsSync("CHANGELOG.md") ? readFileSync("CHANGELOG.md", "utf8") : "";
  const hasChangelogVersion = Boolean(zonVersion && new RegExp(`^##\\s+\\[?${zonVersion.replace(/\./g, "\\.")}\\]?`, "m").test(changelog));

  check(
    "release-alignment",
    "version-parity",
    Boolean(zonVersion && zonVersion === tsVersion && hasChangelogVersion),
    `build.zig.zon=${zonVersion} ts=${tsVersion} changelog=${hasChangelogVersion}`,
  );

  const relPath = ".github/workflows/release.yml";
  if (!existsSync(relPath)) {
    check("release-alignment", relPath, false, "missing .github/workflows/release.yml");
  } else {
    const rel = readFileSync(relPath, "utf8");
    const hasMainTrigger = /branches:\s*\[?\s*['"]?main['"]?\s*\]?/.test(rel) || /branches:\s*\n\s*-\s*main/.test(rel);
    const hasTagTrigger = rel.includes("tags:") && rel.includes("v*");
    const hasDocsJob = rel.includes("docs-publish:") || rel.includes("publish-docs:");
    const ok = hasMainTrigger && hasTagTrigger && hasDocsJob;
    check(
      "release-alignment",
      relPath,
      ok,
      ok ? undefined : `mainTrigger=${hasMainTrigger} tagTrigger=${hasTagTrigger} docsJob=${hasDocsJob}`,
    );
  }
}

// 5. Workflow & playground security
{
  const workflows = [...new Glob(".smithers/workflows/*.ts").scanSync(".")].sort();
  for (const wf of workflows) {
    const src = readFileSync(wf, "utf8");
    let badImport: string | null = null;
    for (const m of src.matchAll(/from\s+["']([^"']+)["']/g)) {
      const mod = m[1]!;
      if (!mod.startsWith("@smthrs/") && mod !== "effect" && !mod.startsWith("effect/")) {
        badImport = `non-QuickJS import "${mod}"`;
        break;
      }
    }
    check("workflow-security", wf, !badImport, badImport ?? undefined);
  }

  const flows = [...new Glob(".smithers/flows/**/flow.mdx").scanSync(".")].sort();
  for (const fl of flows) {
    const text = readFileSync(fl, "utf8");
    const hasFm = text.startsWith("---\n") && text.indexOf("\n---\n", 4) > 0 && /\ndescription:\s*\S+/.test(text);
    check("workflow-security", fl, hasFm, hasFm ? undefined : "flow.mdx missing required description frontmatter");
  }

  const pgPath = ".smithers/playground/index.html";
  if (!existsSync(pgPath)) {
    check("workflow-security", pgPath, false, "missing .smithers/playground/index.html");
  } else {
    const html = readFileSync(pgPath, "utf8");
    const styleMatch = /<style>([\s\S]*?)<\/style>/.exec(html);
    const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(html);
    if (!styleMatch || !scriptMatch) {
      check("workflow-security", pgPath, false, "missing inline style or script block");
    } else {
      const styleHash = `sha256-${createHash("sha256").update(styleMatch[1]!, "utf8").digest("base64")}`;
      const scriptHash = `sha256-${createHash("sha256").update(scriptMatch[1]!, "utf8").digest("base64")}`;
      const ok = html.includes(`'${styleHash}'`) && html.includes(`'${scriptHash}'`) && !html.includes("unsafe-inline");
      check(
        "workflow-security",
        pgPath,
        ok,
        ok ? undefined : "playground CSP SHA-256 hashes do not match inline style/script bytes",
      );
    }
  }
}

appendFileSync(out, lines.join("\n") + "\n");
