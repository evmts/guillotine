import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import test from "node:test"

const zig = process.env.ZIG_EXE ?? "zig"
function run(args, opts = {}) {
  const result = spawnSync(zig, args, { encoding: "utf8", timeout: 120000, ...opts })
  if (result.error) throw result.error
  return result
}
function ok(args, opts = {}) {
  const result = run(args, opts)
  assert.equal(result.status, 0, `${zig} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`)
  return result
}

test("actual Foundry build helper selects the Linux fix and preserves macOS", () => {
  ok(["test", "--dep", "foundry", "-Mroot=.smithers/tests/foundry-config.zig", "-Mfoundry=lib/foundry.zig"])
})

test("#815: Linux archive links into executable without nested-archive LLD warnings", () => {
  mkdirSync(".smithers/cache", { recursive: true })
  const dir = mkdtempSync(resolve(".smithers/cache/foundry-link-"))
  try {
    const path = (name) => `${dir}/${name}`
    writeFileSync(path("value.c"), "int answer(void) { return 42; }\n")
    writeFileSync(path("main.zig"), "extern fn answer() c_int;\npub fn main() void { if (answer() != 42) @panic(\"wrong archive value\"); }\n")
    ok(["cc", "-target", "x86_64-linux-gnu", "-c", path("value.c"), "-o", path("value.o")])
    ok(["ar", "rcs", path("rust.a"), path("value.o")])

    const members = ok(["ar", "t", path("rust.a")]).stdout.trim().split("\n")
    assert.deepEqual(members, ["value.o"])

    const linked = ok(["build-exe", "-fllvm", "-target", "x86_64-linux-gnu", "-flld", path("main.zig"), path("rust.a"), `-femit-bin=${path("fixed")}`])
    assert.doesNotMatch(linked.stderr, /warning:|neither ET_REL nor LLVM bitcode/)
    if (process.platform === "linux" && process.arch === "x64") {
      const executed = spawnSync(path("fixed"), [], { timeout: 10000 })
      if (executed.error) throw executed.error
      assert.equal(executed.status, 0)
    }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
