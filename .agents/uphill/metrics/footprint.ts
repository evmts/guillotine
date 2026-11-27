import { Glob } from "bun";
import { appendFileSync, readFileSync, statSync } from "fs";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];

function isProdZig(path: string): boolean {
  return (
    !path.endsWith("_test.zig") &&
    !path.endsWith("_tests.zig") &&
    !path.endsWith("_bench.zig") &&
    !path.includes("_test_utils/")
  );
}

const prodZig = [...new Glob("src/**/*.zig").scanSync(".")].sort().filter(isProdZig);
const subsystemBytes = new Map<string, number>();

for (const file of prodZig) {
  const lineCount = readFileSync(file, "utf8").split("\n").length;
  lines.push(`file-lines ${file} ${lineCount}`);

  const parts = file.split("/");
  const subsystem = parts.length === 2 ? "src/(root)" : `src/${parts[1]}`;
  subsystemBytes.set(subsystem, (subsystemBytes.get(subsystem) ?? 0) + statSync(file).size);
}

for (const [subsystem, bytes] of [...subsystemBytes.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
  lines.push(`subsystem-size ${subsystem} ${bytes}B`);
}

appendFileSync(out, lines.join("\n") + "\n");
