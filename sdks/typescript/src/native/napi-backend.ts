import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { GuillotineError } from '../errors.js'
import type { HandleToken, NativeBackend, RawExecutionResult } from './backend.js'

interface NapiAddon {
	init(): void
	getLastError(): string
	createEvm(blockInfoBuf: Uint8Array, configByte: number, hardforkId?: number): bigint | null
	destroyEvm(handle: bigint): void
	setBlockInfo(handle: bigint, blockInfoBuf: Uint8Array): boolean
	setBalance(handle: bigint, address: Uint8Array, balance: Uint8Array): boolean
	setNonce(handle: bigint, address: Uint8Array, nonce: bigint): boolean
	getNonce(handle: bigint, address: Uint8Array): bigint | null
	setCode(handle: bigint, address: Uint8Array, code: Uint8Array): boolean
	setStorage(handle: bigint, address: Uint8Array, key: Uint8Array, value: Uint8Array): boolean
	getBalance(handle: bigint, address: Uint8Array): Uint8Array | null
	getStorage(handle: bigint, address: Uint8Array, key: Uint8Array): Uint8Array | null
	getCode(handle: bigint, address: Uint8Array): Uint8Array | null
	call(
		handle: bigint,
		caller: Uint8Array,
		to: Uint8Array,
		value: Uint8Array,
		input: Uint8Array,
		gas: bigint,
		callType: number,
		salt: Uint8Array,
	): RawExecutionResult | null
	simulate(
		handle: bigint,
		caller: Uint8Array,
		to: Uint8Array,
		value: Uint8Array,
		input: Uint8Array,
		gas: bigint,
		callType: number,
		salt: Uint8Array,
	): RawExecutionResult | null
	executeTx(
		handle: bigint,
		txType: number,
		from: Uint8Array,
		to: Uint8Array | null,
		nonce: bigint | null,
		gasLimit: bigint,
		value: Uint8Array,
		gasPrice: Uint8Array,
		maxFeePerGas: Uint8Array | null,
		maxPriorityFeePerGas: Uint8Array,
		input: Uint8Array,
		disableBalanceCheck: boolean,
	): RawExecutionResult | null
}

function asBigInt(handle: HandleToken): bigint {
	return typeof handle === 'bigint' ? handle : BigInt(handle)
}

/** Load the zero-node-gyp Node-API addon (`guillotine.node`) via Node's native loader. */
export function loadNapiBackend(path: string): NativeBackend {
	const require = createRequire(import.meta.url)
	const resolvedPath = resolve(path)
	let addon: NapiAddon
	try {
		addon = require(resolvedPath) as NapiAddon
	} catch (error) {
		throw GuillotineError.initializationFailed(
			`Failed to load Node-API addon at ${resolvedPath}`,
			error instanceof Error ? error : new Error(String(error)),
		)
	}
	addon.init()
	return {
		runtime: 'napi',
		path,
		getLastError: () => addon.getLastError() || 'unknown native error',
		createEvm: (blockInfoBuf, configByte, hardforkId) => addon.createEvm(blockInfoBuf, configByte, hardforkId),
		destroyEvm: (handle) => addon.destroyEvm(asBigInt(handle)),
		setBlockInfo: (handle, blockInfoBuf) => addon.setBlockInfo(asBigInt(handle), blockInfoBuf),
		setBalance: (handle, address, balance) => addon.setBalance(asBigInt(handle), address, balance),
		setNonce: (handle, address, nonce) => addon.setNonce(asBigInt(handle), address, nonce),
		getNonce: (handle, address) => addon.getNonce(asBigInt(handle), address),
		setCode: (handle, address, code) => addon.setCode(asBigInt(handle), address, code),
		setStorage: (handle, address, key, value) => addon.setStorage(asBigInt(handle), address, key, value),
		getBalance: (handle, address) => addon.getBalance(asBigInt(handle), address),
		getStorage: (handle, address, key) => addon.getStorage(asBigInt(handle), address, key),
		getCode: (handle, address) => addon.getCode(asBigInt(handle), address),
		call: (handle, caller, to, value, input, gas, callType, salt) =>
			addon.call(asBigInt(handle), caller, to, value, input, gas, callType, salt),
		simulate: (handle, caller, to, value, input, gas, callType, salt) =>
			addon.simulate(asBigInt(handle), caller, to, value, input, gas, callType, salt),
		executeTx: (
			handle,
			txType,
			from,
			to,
			nonce,
			gasLimit,
			value,
			gasPrice,
			maxFeePerGas,
			maxPriorityFeePerGas,
			input,
			disableBalanceCheck,
		) =>
			addon.executeTx(
				asBigInt(handle),
				txType,
				from,
				to,
				nonce,
				gasLimit,
				value,
				gasPrice,
				maxFeePerGas,
				maxPriorityFeePerGas,
				input,
				disableBalanceCheck,
			),
	}
}
