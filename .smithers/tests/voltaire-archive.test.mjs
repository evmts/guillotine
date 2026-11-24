import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import test from "node:test"

const zig = process.env.ZIG_EXE ?? "zig"

// #862, #863: Voltaire's exported `crypto` and `voltaire` modules link
// lib/voltaire/target/release/libcrypto_wrappers.a. A package that imports them
// must run Voltaire's Cargo build before linking. Stage the vendored package
// with no target/ (a fresh clone) and build a consumer of the exported module.
test("#862/#863: a fresh Voltaire dependency builds its Rust archive for module consumers", () => {
  mkdirSync(".smithers/cache", { recursive: true })
  const dir = mkdtempSync(resolve(".smithers/cache/voltaire-archive-"))
  try {
    cpSync("lib/voltaire", `${dir}/voltaire`, {
      recursive: true,
      filter: (path) => !/[\\/](target|\.zig-cache|zig-out)$/.test(path),
    })
    assert.equal(existsSync(`${dir}/voltaire/target`), false)
    mkdirSync(`${dir}/consumer`)
    writeFileSync(`${dir}/consumer/build.zig.zon`, `.{
    .name = .voltaire_archive_consumer,
    .version = "0.0.0",
    .fingerprint = 0x434884508c6ef709,
    .dependencies = .{ .voltaire = .{ .path = "../voltaire" } },
    .paths = .{""},
}
`)
    writeFileSync(`${dir}/consumer/build.zig`, `const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const voltaire = b.dependency("voltaire", .{ .target = target, .optimize = .Debug });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{.{ .name = "crypto", .module = voltaire.module("crypto") }},
    }) });
    // The Rust archive needs libunwind on Linux, as in src/modules.build.zig.
    if (target.result.os.tag == .linux) exe.root_module.linkSystemLibrary("unwind", .{});
    const run = b.addRunArtifact(exe);
    run.expectExitCode(0);
    b.step("run", "Link and run against the exported crypto module").dependOn(&run.step);
}
`)
    // bn254_ecmul_output_size is defined only in libcrypto_wrappers.a.
    writeFileSync(`${dir}/consumer/main.zig`, `const crypto = @import("crypto");
extern fn bn254_ecmul_output_size() c_uint;
pub fn main() void {
    _ = crypto;
    if (bn254_ecmul_output_size() != 64) @panic("wrong archive value");
}
`)
    const result = spawnSync(zig, ["build", "run"], {
      cwd: `${dir}/consumer`, encoding: "utf8", timeout: 1800000,
      // An inherited CARGO_TARGET_DIR must not move the archive away from Zig.
      env: { ...process.env, CARGO_TARGET_DIR: `${dir}/elsewhere` },
    })
    if (result.error) throw result.error
    assert.equal(result.status, 0, `${zig} build run\n${result.stdout}\n${result.stderr}`)
    assert.doesNotMatch(result.stderr, /libcrypto_wrappers\.a: file not found/)
    assert.equal(existsSync(`${dir}/voltaire/target/release/libcrypto_wrappers.a`), true)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
