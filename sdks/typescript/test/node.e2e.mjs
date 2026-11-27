import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { Address, Bytes, CallType, GuillotineEvm, U256 } from '../dist/index.js'

const here = dirname(fileURLToPath(import.meta.url))
const addonPath =
	process.env.GUILLOTINE_NAPI_PATH || join(here, '..', '..', '..', 'zig-out', 'lib', 'guillotine.node')
assert.ok(existsSync(addonPath), `missing Node-API addon at ${addonPath}; run \`zig build napi\` first`)
process.env.GUILLOTINE_NAPI_PATH = addonPath

const alice = Address.fromHex('0x1000000000000000000000000000000000000001')
const target = Address.fromHex('0x2000000000000000000000000000000000000002')
const coinbase = Address.fromHex('0x3000000000000000000000000000000000000003')

test('Node.js native Node-API addon executes bytecode, state, and simulate', async () => {
	assert.equal(typeof globalThis.Bun, 'undefined', 'expected to run under Node.js, not Bun')
	const evm = await GuillotineEvm.create({ number: 50n, baseFee: 10n, coinbase })
	try {
		assert.equal(evm.runtime, 'napi')
		// PUSH1 20; PUSH1 22; ADD; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN => 42
		const code = Bytes.fromBytes(
			new Uint8Array([0x60, 0x14, 0x60, 0x16, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3]),
		)
		await evm.setCode(target, code)
		assert.deepEqual((await evm.getCode(target)).toBytes(), code.toBytes())

		await evm.setBalance(alice, U256.fromBigInt(1_000_000_000n))
		assert.equal((await evm.getBalance(alice)).toBigInt(), 1_000_000_000n)

		await evm.setStorage(target, U256.fromBigInt(7n), U256.fromBigInt(99n))
		assert.equal((await evm.getStorage(target, U256.fromBigInt(7n))).toBigInt(), 99n)

		const res = await evm.call({
			caller: alice,
			to: target,
			value: U256.zero(),
			input: Bytes.empty(),
			gas: 100_000n,
			callType: CallType.CALL,
		})
		assert.equal(res.success, true)
		assert.equal(U256.fromBytes(res.output.toBytes()).toBigInt(), 42n)

		const sim = await evm.simulate({
			caller: alice,
			to: target,
			value: U256.zero(),
			input: Bytes.empty(),
			gas: 100_000n,
		})
		assert.equal(sim.success, true)
		assert.equal(U256.fromBytes(sim.output.toBytes()).toBigInt(), 42n)
	} finally {
		evm.dispose()
	}
})

test('Node.js native Node-API addon supports setBlockInfo, executeTx, callTracer, and hardforks', async () => {
	const evm = await GuillotineEvm.create({ number: 1n, baseFee: 10n, coinbase }, { callTracer: true })
	try {
		assert.equal(evm.callTracer, true)
		// NUMBER; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN
		await evm.setCode(target, Bytes.fromBytes(new Uint8Array([0x43, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3])))
		await evm.setBlockInfo({ number: 123456n, baseFee: 10n, coinbase })
		await evm.setBalance(alice, U256.fromBigInt(1_000_000_000n))

		const tx = await evm.executeTx({
			from: alice,
			to: target,
			nonce: 0n,
			gasLimit: 100_000n,
			maxFeePerGas: U256.fromBigInt(20n),
			maxPriorityFeePerGas: U256.fromBigInt(5n),
		})
		assert.equal(tx.success, true)
		assert.equal(U256.fromBytes(tx.output.toBytes()).toBigInt(), 123456n)
		assert.equal(await evm.getNonce(alice), 1n)
		assert.ok(tx.traceJson && tx.traceJson.includes('"type":"CALL"'))
	} finally {
		evm.dispose()
	}

	const shanghai = await GuillotineEvm.create({}, { hardfork: 'shanghai' })
	try {
		// TSTORE should fail on Shanghai
		await shanghai.setCode(target, Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x60, 0x00, 0x5d, 0x00])))
		const res = await shanghai.call({
			caller: alice,
			to: target,
			value: U256.zero(),
			input: Bytes.empty(),
			gas: 100_000n,
		})
		assert.equal(res.success, false)
	} finally {
		shanghai.dispose()
	}
})
