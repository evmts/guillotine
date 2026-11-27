import { Glob } from "bun";
import { appendFileSync, readFileSync } from "fs";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

function isProdZig(path: string): boolean {
  return (
    !path.endsWith("_test.zig") &&
    !path.endsWith("_tests.zig") &&
    !path.endsWith("_bench.zig") &&
    !path.includes("_test_utils/")
  );
}

function stripLine(line: string): string {
  return line.replace(/\/\/.*$/, "").replace(/"(?:\\.|[^"\\])*"/g, '""');
}

const zigFiles = [...new Glob("src/**/*.zig").scanSync(".")].sort().filter(isProdZig);
let totalProdLines = 0;
let totalAsserts = 0;

for (const file of zigFiles) {
  const raw = readFileSync(file, "utf8").split("\n");
  let panicHit: string | null = null;
  let debugHit: string | null = null;
  let swallowHit: string | null = null;

  for (let i = 0; i < raw.length; i++) {
    const line = raw[i]!;
    if (/^test\s*(?:"[^"]*")?\s*\{/.test(line)) break;
    totalProdLines++;
    const code = stripLine(line);

    if (/\bassert\s*\(/.test(code)) totalAsserts++;

    if (!panicHit) {
      if (/@panic\s*\(/.test(code)) {
        panicHit = `line ${i + 1}: @panic() in production code`;
      } else if (/\bcatch\s+unreachable\b/.test(code)) {
        panicHit = `line ${i + 1}: catch unreachable in production code`;
      } else if (/\bunreachable\b/.test(code)) {
        panicHit = `line ${i + 1}: unreachable in production code`;
      }
    }

    if (!debugHit) {
      if (code.includes("std.debug.assert")) {
        debugHit = `line ${i + 1}: std.debug.assert (use tracer.assert)`;
      } else if (code.includes("std.debug.print")) {
        debugHit = `line ${i + 1}: std.debug.print (use log.zig)`;
      }
    }

    if (!swallowHit) {
      if (/\bcatch\s*\{\s*\}/.test(code)) {
        swallowHit = `line ${i + 1}: empty catch {} swallows error`;
      } else if (/\bcatch\s+null\b/.test(code)) {
        swallowHit = `line ${i + 1}: catch null swallows error`;
      } else if (/\bcatch\s+&\.\{\s*\}/.test(code)) {
        swallowHit = `line ${i + 1}: catch &.{} swallows error`;
      } else if (code.includes("error.NotImplemented")) {
        swallowHit = `line ${i + 1}: error.NotImplemented stub`;
      }
    }
  }

  lines.push(
    panicHit
      ? `zig-no-panic ${file} fail note ${q(panicHit)}`
      : `zig-no-panic ${file} pass`,
  );
  lines.push(
    debugHit
      ? `zig-no-forbidden-debug ${file} fail note ${q(debugHit)}`
      : `zig-no-forbidden-debug ${file} pass`,
  );
  lines.push(
    swallowHit
      ? `zig-no-swallowed-errors ${file} fail note ${q(swallowHit)}`
      : `zig-no-swallowed-errors ${file} pass`,
  );
}

const density = totalProdLines > 0 ? (totalAsserts * 1000) / totalProdLines : 0;
lines.push(`zig-assertion-density ${density.toFixed(2)}`);

const rustFiles = [
  ...new Glob("lib/ark/src/**/*.rs").scanSync("."),
  ...new Glob("lib/foundry-compilers/src/**/*.rs").scanSync("."),
].sort();

for (const file of rustFiles) {
  const raw = readFileSync(file, "utf8").split("\n");
  let unwrapHit: string | null = null;
  let unsafeCount = 0;
  let inCfgTest = false;

  for (let i = 0; i < raw.length; i++) {
    const line = raw[i]!;
    if (/^\s*#\[cfg\(test\)\]/.test(line)) inCfgTest = true;
    if (inCfgTest) continue;
    const code = stripLine(line);
    if (!unwrapHit && /\.(unwrap|expect)\s*\(/.test(code)) {
      unwrapHit = `line ${i + 1}: .unwrap()/.expect() in Rust FFI crate`;
    }
    const unsafeMatches = code.match(/\bunsafe\b/g);
    if (unsafeMatches) unsafeCount += unsafeMatches.length;
  }

  lines.push(
    unwrapHit
      ? `rust-no-unwrap ${file} fail note ${q(unwrapHit)}`
      : `rust-no-unwrap ${file} pass`,
  );
  lines.push(`rust-unsafe-blocks ${file} ${unsafeCount}`);
}

appendFileSync(out, lines.join("\n") + "\n");
