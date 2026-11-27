/**
 * Runtime-agnostic interface over Guillotine's native EVM engine.
 * Implemented by both the Node-API addon (`guillotine.node`, working in Node.js >=20,
 * Bun >=1.1, and Deno) and Bun FFI (`libguillotine_ffi.{dylib,so,dll}`).
 */

export type HandleToken = bigint | number

export interface RawLogEntry {
	readonly address: Uint8Array
	readonly topics: readonly Uint8Array[]
	readonly data: Uint8Array
}

export interface RawSelfDestructRecord {
	readonly contract: Uint8Array
	readonly beneficiary: Uint8Array
}

export interface RawStorageAccessRecord {
	readonly address: Uint8Array
	readonly slot: Uint8Array
}

export interface RawExecutionResult {
	readonly success: boolean
	readonly gasLeft: bigint
	readonly output: Uint8Array
	readonly errorMessage: string | null
	readonly logs: readonly RawLogEntry[]
	readonly selfdestructs: readonly RawSelfDestructRecord[]
	readonly accessedAddresses: readonly Uint8Array[]
	readonly accessedStorage: readonly RawStorageAccessRecord[]
	readonly createdAddress: Uint8Array | null
	readonly traceJson: string | null
}

export interface NativeBackend {
	readonly runtime: 'napi' | 'bun-ffi'
	readonly path: string
	getLastError(): string
	createEvm(blockInfoBuf: Uint8Array, configByte: number, hardforkId?: number): HandleToken | null
	destroyEvm(handle: HandleToken): void
	setBlockInfo(handle: HandleToken, blockInfoBuf: Uint8Array): boolean
	setBalance(handle: HandleToken, address: Uint8Array, balance: Uint8Array): boolean
	setNonce(handle: HandleToken, address: Uint8Array, nonce: bigint): boolean
	getNonce(handle: HandleToken, address: Uint8Array): bigint | null
	setCode(handle: HandleToken, address: Uint8Array, code: Uint8Array): boolean
	setStorage(handle: HandleToken, address: Uint8Array, key: Uint8Array, value: Uint8Array): boolean
	getBalance(handle: HandleToken, address: Uint8Array): Uint8Array | null
	getStorage(handle: HandleToken, address: Uint8Array, key: Uint8Array): Uint8Array | null
	getCode(handle: HandleToken, address: Uint8Array): Uint8Array | null
	call(
		handle: HandleToken,
		caller: Uint8Array,
		to: Uint8Array,
		value: Uint8Array,
		input: Uint8Array,
		gas: bigint,
		callType: number,
		salt: Uint8Array,
	): RawExecutionResult | null
	simulate(
		handle: HandleToken,
		caller: Uint8Array,
		to: Uint8Array,
		value: Uint8Array,
		input: Uint8Array,
		gas: bigint,
		callType: number,
		salt: Uint8Array,
	): RawExecutionResult | null
	executeTx(
		handle: HandleToken,
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
