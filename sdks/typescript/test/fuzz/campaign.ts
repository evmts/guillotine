#!/usr/bin/env bun
/**
 * Continuous TypeScript SDK + Bun FFI Fuzz Campaign Runner
 *
 * Usage:
 *   bun test/fuzz/campaign.ts --executions=5000 --seed=42
 *   GUILLOTINE_FUZZ_EXECS=10000 bun run test:fuzz
 */

import { GuillotineEvm, CallType } from '../../src/evm/evm.js'
import { Address, Bytes, U256 } from '../../src/primitives/index.js'
import { runFuzz, type FuzzTape } from './engine.js'

const args = process.argv.slice(2)
let executions = 2000
let seed = Date.now() >>> 0

for (const arg of args) {
	if (arg.startsWith('--executions=')) executions = Number(arg.slice('--executions='.length))
	if (arg.startsWith('--seed=')) seed = Number(arg.slice('--seed='.length))
}

function makeAddr(id: number): Address {
	const b = new Uint8Array(20)
	b[19] = (id & 0xff) || 1
	return Address.fromBytes(b)
}

function genProgram(tape: FuzzTape, rng: () => number): Uint8Array {
	const ops: number[] = []
	const n = tape.int(1, 24, rng)
	const opPool = [0x01, 0x02, 0x03, 0x04, 0x06, 0x10, 0x14, 0x15, 0x16, 0x17, 0x18, 0x51, 0x52, 0x54, 0x55, 0x5c, 0x5d, 0x5e]
	ops.push(0x60, tape.nat(256, rng), 0x60, tape.nat(256, rng))
	for (let i = 0; i < n; i++) {
		if (tape.bool(rng)) {
			ops.push(0x60, tape.nat(64, rng))
		}
		ops.push(tape.pick(opPool, rng))
	}
	ops.push(0x60, 0x20, 0x60, 0x00, tape.nat(5, rng) === 0 ? 0xfd : 0xf3)
	return new Uint8Array(ops)
}

console.log(`[ts-fuzz] starting campaign: executions=${executions} seed=${seed}`)
const t0 = performance.now()

const report = await runFuzz(
	(tape, rng) => ({
		code: genProgram(tape, rng),
		calldata: tape.bytes(0, 64, rng),
		callType: tape.pick(
			[CallType.CALL, CallType.CALLCODE, CallType.DELEGATECALL, CallType.STATICCALL, CallType.CREATE, CallType.CREATE2],
			rng,
		),
		gas: BigInt(tape.pick([21_000, 35_000, 100_000, 500_000], rng)),
		salt: U256.fromBigInt(BigInt(tape.nextU32(rng))),
	}),
	async ({ code, calldata, callType, gas, salt }, ctx) => {
		const caller = makeAddr(0x11)
		const target = makeAddr(0x22)
		const evm = await GuillotineEvm.create({ number: 20_000_000n, chainId: 1n })
		try {
			await evm.setBalance(caller, U256.fromBigInt(10_000_000_000n))
			await evm.setCode(target, Bytes.fromBytes(code))

			const params = {
				caller,
				to: target,
				value: U256.zero(),
				input: Bytes.fromBytes(callType === CallType.CREATE || callType === CallType.CREATE2 ? code : calldata),
				gas,
				callType,
				salt,
			}

			const res = await evm.call(params)
			if (callType === CallType.CALL) {
				const evm2 = await GuillotineEvm.create({ number: 20_000_000n, chainId: 1n })
				try {
					await evm2.setBalance(caller, U256.fromBigInt(10_000_000_000n))
					await evm2.setCode(target, Bytes.fromBytes(code))
					const sim = await evm2.simulate(params)
					if (sim.success !== res.success || sim.gasLeft !== res.gasLeft) {
						throw new Error(`simulate/call mismatch: sim=(${sim.success},${sim.gasLeft}) call=(${res.success},${res.gasLeft})`)
					}
				} finally {
					evm2.dispose()
				}
			}
			if (res.gasLeft > gas) {
				throw new Error(`gasLeft ${res.gasLeft} exceeded gas limit ${gas}`)
			}

			ctx.observe(`ct:${callType}:${res.success ? 'ok' : 'fail'}`)
			if (res.logs.length > 0) ctx.observe('logs')
			if (res.createdAddress) ctx.observe('created')
			ctx.score('gasUsed', Number(gas - res.gasLeft))
		} finally {
			evm.dispose()
		}
	},
	{ executions, seed },
)

const ms = performance.now() - t0
console.log(
	`[ts-fuzz] finished: passed=${report.passed} execs=${report.executions} corpus=${report.corpusSize} features=${report.featuresCount} elapsed=${ms.toFixed(1)}ms (${((report.executions * 1000) / ms).toFixed(0)} exec/s)`,
)

if (!report.passed && report.finding) {
	console.error('[ts-fuzz] FAILURE:', report.finding.error)
	console.error('[ts-fuzz] REPLAY TOKEN:', report.finding.replayToken)
	process.exit(1)
}
