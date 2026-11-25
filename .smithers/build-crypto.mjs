import { spawnSync } from "node:child_process"

// lib/voltaire/Cargo.toml declares its own [workspace], so Cargo builds it
// standalone without touching the root workspace. Build it in place; the
// Zig build links lib/voltaire/target/release/libcrypto_wrappers.a.
const result = spawnSync("cargo", ["build", "--release", "--locked", "--manifest-path", "lib/voltaire/Cargo.toml"],
  { stdio: "inherit", timeout: 3600000 })
if (result.error) throw result.error
if (result.signal) throw new Error(`Voltaire Cargo build terminated by ${result.signal}`)
process.exitCode = result.status
