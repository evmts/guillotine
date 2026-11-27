#!/usr/bin/env node
/**
 * Bounded Guillotine EVM Playground runner.
 *
 * Accepts one JSON request as argv[2] (or stdin):
 *   { "mode": "analyze" | "execute", "bytecode": "0x...", "calldata": "0x...", "gas": 100000, "hardfork": "OSAKA" }
 *
 * - "analyze": pure deterministic EVM bytecode disassembler, basic-block boundary
 *   detector, JUMPDEST bitmap extractor, and fusion opportunity preview (works
 *   anywhere with zero native binary dependency).
 * - "execute": runs bytecode against the real compiled Guillotine native library
 *   (libguillotine_ffi) via Bun when available, returning exact gasUsed, returnData,
 *   and success/revert status. Never fabricates execution results when the native
 *   library is not built.
 */
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { resolve } from "node:path"

const MAX_BYTECODE_BYTES = 4096
const MAX_CALLDATA_BYTES = 2048
const MIN_GAS = 21_000
const MAX_GAS = 500_000
const HARDFORKS = new Set([
  "FRONTIER", "HOMESTEAD", "TANGERINE_WHISTLE", "SPURIOUS_DRAGON",
  "BYZANTIUM", "CONSTANTINOPLE", "PETERSBURG", "ISTANBUL",
  "BERLIN", "LONDON", "SHANGHAI", "CANCUN", "PRAGUE", "OSAKA"
])

const OPCODES = {
  0x00: "STOP", 0x01: "ADD", 0x02: "MUL", 0x03: "SUB", 0x04: "DIV", 0x05: "SDIV",
  0x06: "MOD", 0x07: "SMOD", 0x08: "ADDMOD", 0x09: "MULMOD", 0x0a: "EXP", 0x0b: "SIGNEXTEND",
  0x10: "LT", 0x11: "GT", 0x12: "SLT", 0x13: "SGT", 0x14: "EQ", 0x15: "ISZERO",
  0x16: "AND", 0x17: "OR", 0x18: "XOR", 0x19: "NOT", 0x1a: "BYTE", 0x1b: "SHL", 0x1c: "SHR", 0x1d: "SAR", 0x1e: "CLZ",
  0x20: "KECCAK256",
  0x30: "ADDRESS", 0x31: "BALANCE", 0x32: "ORIGIN", 0x33: "CALLER", 0x34: "CALLVALUE",
  0x35: "CALLDATALOAD", 0x36: "CALLDATASIZE", 0x37: "CALLDATACOPY", 0x38: "CODESIZE",
  0x39: "CODECOPY", 0x3a: "GASPRICE", 0x3b: "EXTCODESIZE", 0x3c: "EXTCODECOPY",
  0x3d: "RETURNDATASIZE", 0x3e: "RETURNDATACOPY", 0x3f: "EXTCODEHASH",
  0x50: "POP", 0x51: "MLOAD", 0x52: "MSTORE", 0x53: "MSTORE8", 0x54: "SLOAD", 0x55: "SSTORE",
  0x56: "JUMP", 0x57: "JUMPI", 0x58: "PC", 0x59: "MSIZE", 0x5a: "GAS", 0x5b: "JUMPDEST",
  0x5c: "TLOAD", 0x5d: "TSTORE", 0x5e: "MCOPY", 0x5f: "PUSH0",
  0xf0: "CREATE", 0xf1: "CALL", 0xf2: "CALLCODE", 0xf3: "RETURN", 0xf4: "DELEGATECALL",
  0xf5: "CREATE2", 0xfa: "STATICCALL", 0xfd: "REVERT", 0xfe: "INVALID", 0xff: "SELFDESTRUCT"
}

export function opcodeName(byte) {
  if (byte >= 0x60 && byte <= 0x7f) return `PUSH${byte - 0x5f}`
  if (byte >= 0x80 && byte <= 0x8f) return `DUP${byte - 0x7f}`
  if (byte >= 0x90 && byte <= 0x9f) return `SWAP${byte - 0x8f}`
  if (byte >= 0xa0 && byte <= 0xa4) return `LOG${byte - 0xa0}`
  return OPCODES[byte] ?? `INVALID(0x${byte.toString(16).padStart(2, "0")})`
}

export function validateRequest(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { error: "Request must be a JSON object" }
  }
  const mode = raw.mode === "execute" ? "execute" : raw.mode === "analyze" ? "analyze" : null
  if (!mode) return { error: "mode must be 'analyze' or 'execute'" }

  const bytecode = typeof raw.bytecode === "string" ? raw.bytecode.trim() : ""
  const calldata = typeof raw.calldata === "string" ? raw.calldata.trim() : "0x"
  if (!/^0x(?:[0-9a-f]{2})*$/i.test(bytecode)) return { error: "bytecode must be even-length hex starting with 0x" }
  if (!/^0x(?:[0-9a-f]{2})*$/i.test(calldata)) return { error: "calldata must be even-length hex starting with 0x" }
  if ((bytecode.length - 2) / 2 > MAX_BYTECODE_BYTES) return { error: `bytecode exceeds ${MAX_BYTECODE_BYTES} bytes` }
  if ((calldata.length - 2) / 2 > MAX_CALLDATA_BYTES) return { error: `calldata exceeds ${MAX_CALLDATA_BYTES} bytes` }

  const gas = Number(raw.gas ?? 100_000)
  if (!Number.isInteger(gas) || gas < MIN_GAS || gas > MAX_GAS) {
    return { error: `gas must be an integer between ${MIN_GAS} and ${MAX_GAS}` }
  }

  const hardfork = typeof raw.hardfork === "string" ? raw.hardfork.toUpperCase() : "OSAKA"
  if (!HARDFORKS.has(hardfork)) return { error: `unsupported hardfork: ${hardfork}` }

  return { mode, bytecode: bytecode.toLowerCase(), calldata: calldata.toLowerCase(), gas, hardfork }
}

export function analyzeBytecode(hex) {
  const bytes = Buffer.from(hex.slice(2), "hex")
  const ops = []
  const jumpdests = []
  const fusions = []

  let pc = 0
  while (pc < bytes.length) {
    const op = bytes[pc]
    const name = opcodeName(op)
    let imm = null
    let size = 1
    if (op >= 0x60 && op <= 0x7f) {
      const n = op - 0x5f
      const slice = bytes.subarray(pc + 1, Math.min(bytes.length, pc + 1 + n))
      imm = "0x" + slice.toString("hex").padEnd(n * 2, "0")
      size = 1 + n
    }
    if (op === 0x5b) jumpdests.push(pc)
    ops.push({ pc, opcode: `0x${op.toString(16).padStart(2, "0")}`, name, ...(imm ? { imm } : {}) })
    pc += size
  }

  // Detect Guillotine synthetic fusion patterns in the decoded stream.
  for (let i = 0; i < ops.length; i++) {
    const a = ops[i]
    const b = ops[i + 1]
    const c = ops[i + 2]
    if (a.name === "ISZERO" && b && b.name.startsWith("PUSH") && c && c.name === "JUMPI") {
      fusions.push({ pc: a.pc, pattern: "ISZERO_PUSH_JUMPI", ops: [a.name, b.name, c.name] })
      i += 2
    } else if (a.name.startsWith("PUSH") && b && ["ADD", "SUB", "MUL", "AND", "OR", "XOR", "MSTORE", "MLOAD", "JUMP", "JUMPI"].includes(b.name)) {
      fusions.push({ pc: a.pc, pattern: `PUSH_${b.name}`, ops: [a.name, b.name] })
      i += 1
    } else if (a.name.startsWith("DUP") && b && b.name === "MSTORE") {
      fusions.push({ pc: a.pc, pattern: "DUP_MSTORE", ops: [a.name, b.name] })
      i += 1
    }
  }

  const blockTerminators = new Set(["STOP", "JUMP", "JUMPI", "RETURN", "REVERT", "INVALID", "SELFDESTRUCT"])
  let blocks = ops.length > 0 ? 1 : 0
  for (let i = 0; i < ops.length - 1; i++) {
    if (blockTerminators.has(ops[i].name) || ops[i + 1].name === "JUMPDEST") {
      blocks++
    }
  }

  return {
    byteLength: bytes.length,
    instructionCount: ops.length,
    basicBlocks: blocks,
    jumpdests,
    fusions,
    instructions: ops.slice(0, 256)
  }
}

export function executeNative(req, repoRoot = process.cwd()) {
  const libName = process.platform === "darwin" ? "libguillotine_ffi.dylib" : "libguillotine_ffi.so"
  const candidates = [
    process.env.GUILLOTINE_LIB_PATH,
    resolve(repoRoot, "zig-out/lib", libName),
    resolve(repoRoot, "sdks/typescript/prebuilds", `${process.platform === "darwin" ? "darwin-arm64" : "linux-x64"}`, libName)
  ].filter(Boolean)
  const libPath = candidates.find((p) => existsSync(p))
  if (!libPath) {
    return {
      error: "Native library not built yet. Run `zig build shared -Doptimize=ReleaseFast` or switch to Analyze mode.",
      analysis: analyzeBytecode(req.bytecode)
    }
  }

  const script = `
    import { createEvm, Hardfork } from "./sdks/typescript/src/index.ts";
    const req = JSON.parse(process.env.PLAYGROUND_REQ);
    const evm = createEvm({ hardfork: Hardfork[req.hardfork] ?? Hardfork.OSAKA });
    try {
      const caller = "0x1000000000000000000000000000000000000001";
      const target = "0x2000000000000000000000000000000000000002";
      evm.setBalance(caller, 10n ** 18n);
      evm.setCode(target, req.bytecode);
      const res = evm.call({ caller, to: target, data: req.calldata, gas: BigInt(req.gas), value: 0n });
      console.log(JSON.stringify({
        success: res.success,
        gasUsed: Number(res.gasUsed ?? (BigInt(req.gas) - BigInt(res.gasLeft ?? 0n))),
        gasLeft: Number(res.gasLeft ?? 0n),
        output: res.output ?? "0x"
      }));
    } finally {
      evm.close();
    }
  `
  const proc = spawnSync("bun", ["-e", script], {
    cwd: repoRoot,
    env: { ...process.env, GUILLOTINE_LIB_PATH: libPath, PLAYGROUND_REQ: JSON.stringify(req) },
    encoding: "utf8",
    timeout: 8000
  })
  if (proc.status !== 0) {
    return {
      error: (proc.stderr || proc.stdout || "Guillotine native execution failed").trim().slice(0, 240),
      analysis: analyzeBytecode(req.bytecode)
    }
  }
  try {
    const execResult = JSON.parse(proc.stdout.trim())
    return { ...execResult, hardfork: req.hardfork, analysis: analyzeBytecode(req.bytecode) }
  } catch {
    return { error: "Malformed response from Guillotine runner" }
  }
}

export function runPlayground(raw, repoRoot = process.cwd()) {
  const req = validateRequest(raw)
  if ("error" in req) return req
  if (req.mode === "analyze") {
    return { mode: "analyze", hardfork: req.hardfork, ...analyzeBytecode(req.bytecode) }
  }
  return { mode: "execute", ...executeNative(req, repoRoot) }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const rawArg = process.argv[2] ?? "{}"
  let parsed
  try {
    parsed = JSON.parse(rawArg)
  } catch {
    console.log(JSON.stringify({ error: "Invalid JSON request" }))
    process.exit(0)
  }
  console.log(JSON.stringify(runPlayground(parsed)))
}
