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

// 1. Lean 4 proofs in verify/lean/
const leanFiles = [...new Glob("verify/lean/**/*.lean").scanSync(".")].sort();
let totalTheorems = 0;

for (const file of leanFiles) {
  const raw = readFileSync(file, "utf8");
  const fileLines = raw.split("\n");
  let sorryHit: string | null = null;
  for (let i = 0; i < fileLines.length; i++) {
    const code = fileLines[i]!.replace(/--.*$/, "");
    if (/^\s*(?:theorem|lemma)\s+/.test(code)) totalTheorems++;
    if (!sorryHit && /\bsorry\b/.test(code)) {
      sorryHit = `line ${i + 1}: unproved sorry in Lean proof`;
    } else if (!sorryHit && /^\s*axiom\s+/.test(code)) {
      sorryHit = `line ${i + 1}: unproved axiom in Lean proof`;
    }
  }
  lines.push(
    sorryHit
      ? `lean-no-sorry ${file} fail note ${q(sorryHit)}`
      : `lean-no-sorry ${file} pass`,
  );
}
lines.push(`lean-theorems ${totalTheorems}`);

// 2. SMT-LIB2 proofs in verify/smt/proofs/
const smtFiles = [...new Glob("verify/smt/**/*.smt2").scanSync(".")].sort();
lines.push(`smt-proofs ${smtFiles.length}`);

// 3. Inline test coverage across production src/**/*.zig
const prodZig = [...new Glob("src/**/*.zig").scanSync(".")].sort().filter(isProdZig);
let withTests = 0;
for (const file of prodZig) {
  const txt = readFileSync(file, "utf8");
  if (/^\s*test\s*(?:"[^"]*")?\s*\{/m.test(txt)) withTests++;
}
const pct = prodZig.length > 0 ? Math.round((withTests * 1000) / prodZig.length) / 10 : 0;
lines.push(`inline-test-coverage ${pct}`);

appendFileSync(out, lines.join("\n") + "\n");
