import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import test from "node:test"

const zig = process.env.ZIG_EXE ?? "zig"
function run(args) {
  const result = spawnSync(zig, args, { encoding: "utf8", timeout: 120000 })
  if (result.error) throw result.error
  return result
}
function ok(args) {
  const result = run(args)
  assert.equal(result.status, 0, `${zig} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`)
  return result
}

test("actual Foundry build helper selects the Linux fix and preserves macOS", () => {
  ok(["test", "--dep", "foundry", "-Mroot=.smithers/tests/foundry-config.zig", "-Mfoundry=lib/foundry.zig"])
})

test("#815: Linux archive objects flatten and link without LLD warnings", () => {
  mkdirSync(".smithers/cache", { recursive: true })
  const dir = mkdtempSync(resolve(".smithers/cache/foundry-link-"))
  try {
    const path = (name) => `${dir}/${name}`
    // The failure depends on archive structure, not the source language of its objects.
    writeFileSync(path("value.c"), "int answer(void) { return 42; }\n")
    writeFileSync(path("main.zig"), 'extern fn answer() c_int;\npub fn main() void { if (answer() != 42) @panic("wrong archive value"); }\n')
    ok(["cc", "-target", "x86_64-linux-gnu", "-c", path("value.c"), "-o", path("value.o")])
    ok(["ar", "rcs", path("rust.a"), path("value.o")])
    ok(["build-lib", "-target", "x86_64-linux-gnu", "-static", "-flld", path("rust.a"), `-femit-bin=${path("nested.a")}`])
    assert.match(ok(["ar", "t", path("nested.a")]).stdout, /rust\.a/)
    const broken = run(["build-exe", "-fllvm", "-target", "x86_64-linux-gnu", "-flld", path("main.zig"), path("nested.a"), `-femit-bin=${path("broken")}`])
    assert.notEqual(broken.status, 0, "Nested archive unexpectedly linked")
    assert.match(broken.stderr, /neither ET_REL nor LLVM bitcode|undefined symbol: answer/)

    ok(["build-lib", "-target", "x86_64-linux-gnu", "-static", "-fno-lld", path("rust.a"), `-femit-bin=${path("flat.a")}`])
    const members = ok(["ar", "t", path("flat.a")]).stdout.trim().split("\n")
    assert.deepEqual(members, ["value.o"])
    const linked = ok(["build-exe", "-fllvm", "-target", "x86_64-linux-gnu", "-flld", path("main.zig"), path("flat.a"), `-femit-bin=${path("fixed")}`])
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
