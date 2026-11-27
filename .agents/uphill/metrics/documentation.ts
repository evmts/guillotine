import { Glob } from "bun";
import { appendFileSync, existsSync, readdirSync, readFileSync, statSync } from "fs";
import { dirname, join, resolve } from "path";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

// 1. Broken local links in root *.md and docs/**/*.md
const mdFiles = [
  ...new Glob("*.md").scanSync("."),
  ...new Glob("docs/**/*.md").scanSync("."),
].sort();

for (const file of mdFiles) {
  const raw = readFileSync(file, "utf8");
  // Strip fenced code blocks before checking links
  const stripped = raw.replace(/```[\s\S]*?```/g, "");
  let broken: string | null = null;
  for (const m of stripped.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
    const target = m[1]!.trim().split(/\s+/)[0]!;
    if (
      !target ||
      target.startsWith("http://") ||
      target.startsWith("https://") ||
      target.startsWith("mailto:") ||
      target.startsWith("#") ||
      target.startsWith("data:")
    ) {
      continue;
    }
    const clean = target.split("#")[0]!.split("?")[0]!;
    if (!clean) continue;
    const candidate = clean.startsWith("/")
      ? resolve(".", clean.slice(1))
      : resolve(dirname(file), clean);
    if (
      !existsSync(candidate) &&
      !existsSync(`${candidate}.md`) &&
      !existsSync(`${candidate}.mdx`)
    ) {
      broken = `broken link: ${target}`;
      break;
    }
  }
  lines.push(
    broken
      ? `broken-links ${file} fail note ${q(broken)}`
      : `broken-links ${file} pass`,
  );
}

// 2. Subsystem README.md coverage under src/
for (const entry of readdirSync("src").sort()) {
  if (entry.startsWith("_")) continue;
  const full = join("src", entry);
  if (!statSync(full).isDirectory()) continue;
  const hasReadme = existsSync(join(full, "README.md"));
  lines.push(
    hasReadme
      ? `subdir-readme ${full} pass`
      : `subdir-readme ${full} fail note "missing ${full}/README.md"`,
  );
}

appendFileSync(out, lines.join("\n") + "\n");
