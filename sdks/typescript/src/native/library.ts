import { CString, dlopen, FFIType, type Pointer, ptr, read, suffix, toArrayBuffer } from 'bun:ffi'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { GuillotineError } from '../errors.js'

/**
 * Symbols from `sdks/c/include/guillotine.h` (the ABI of `src/evm_c_api.zig`)
 * that this SDK binds. Mainnet and tracing handles have different native types;
 * see `docs/building-custom-sdks.md` for the compatible-operation matrix.
 */
const symbols = {
	guillotine_init: { args: [], returns: FFIType.void },
	guillotine_get_last_error: { args: [], returns: FFIType.cstring },
	guillotine_evm_create: { args: [FFIType.ptr], returns: FFIType.ptr },
	guillotine_evm_create_tracing: { args: [FFIType.ptr], returns: FFIType.ptr },
	guillotine_evm_destroy: { args: [FFIType.ptr], returns: FFIType.void },
	guillotine_evm_destroy_tracing: { args: [FFIType.ptr], returns: FFIType.void },
	guillotine_set_balance: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
	guillotine_set_balance_tracing: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
	guillotine_set_nonce: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.bool },
	guillotine_set_nonce_tracing: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.bool },
	guillotine_set_code: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.bool },
	guillotine_set_code_tracing: {
		args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64],
		returns: FFIType.bool,
	},
	guillotine_set_storage: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
	guillotine_get_balance: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
	guillotine_get_storage: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
	guillotine_get_code: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
	guillotine_free_code: { args: [FFIType.ptr, FFIType.u64], returns: FFIType.void },
	guillotine_call: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
	guillotine_call_tracing: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
	guillotine_simulate: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
	guillotine_free_result: { args: [FFIType.ptr], returns: FFIType.void },
} as const

export type NativeSymbols = ReturnType<typeof dlopen<typeof symbols>>['symbols']

export const LIBRARY_ENV = 'GUILLOTINE_LIB_PATH'
const LIBRARY_FILE = `libguillotine_ffi.${suffix}`

/** Directory holding prebuilt native libraries inside the published package. */
function prebuildPath(): string {
	const here = dirname(fileURLToPath(import.meta.url))
	// dist/index.js is one level below the package root; src/native/library.ts is two.
	const root = existsSync(join(here, '..', 'package.json')) ? join(here, '..') : join(here, '..', '..')
	return join(root, 'prebuilds', `${process.platform}-${process.arch}`, LIBRARY_FILE)
}

/** Resolve the native library: explicit path, then `GUILLOTINE_LIB_PATH`, then the bundled prebuild. */
export function resolveLibraryPath(explicit?: string): string {
	if (explicit !== undefined) return explicit
	const fromEnv = process.env[LIBRARY_ENV]
	if (fromEnv !== undefined && fromEnv !== '') return fromEnv
	return prebuildPath()
}

let loaded: { path: string; symbols: NativeSymbols } | null = null

/**
 * Load `libguillotine_ffi` once per process and call `guillotine_init`.
 * The native allocator and error buffer are thread-local, so every call must run
 * on the JS thread that loaded the library. Bun FFI calls are synchronous on that thread.
 */
export function loadNative(libraryPath?: string): NativeSymbols {
	const path = resolveLibraryPath(libraryPath)
	if (loaded !== null) {
		if (libraryPath !== undefined && loaded.path !== path) {
			throw GuillotineError.initializationFailed(
				`libguillotine_ffi is already loaded from ${loaded.path}; cannot load a second copy from ${path}`,
			)
		}
		return loaded.symbols
	}
	if (new Uint8Array(new Uint16Array([1]).buffer)[0] !== 1) {
		throw GuillotineError.initializationFailed('Guillotine FFI requires a little-endian host')
	}
	if (!existsSync(path)) {
		throw GuillotineError.initializationFailed(
			`Native library not found at ${path}. Build it with \`zig build shared\` and set ${LIBRARY_ENV}, or install a package with prebuilds for ${process.platform}-${process.arch}.`,
		)
	}
	let lib: ReturnType<typeof dlopen<typeof symbols>>
	try {
		lib = dlopen(path, symbols)
	} catch (error) {
		throw GuillotineError.initializationFailed(
			`Failed to load ${path}`,
			error instanceof Error ? error : new Error(String(error)),
		)
	}
	lib.symbols.guillotine_init()
	loaded = { path, symbols: lib.symbols }
	return lib.symbols
}

/** Normalize a native pointer return value; Bun may return a bigint for wide addresses. */
export function toPointer(value: bigint | Pointer | null): Pointer | null {
	if (value === null || value === 0 || value === 0n) return null
	if (typeof value === 'bigint') {
		if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
			throw GuillotineError.memoryError(`Native pointer 0x${value.toString(16)} exceeds Number.MAX_SAFE_INTEGER`)
		}
		return Number(value) as Pointer
	}
	return value
}

/** Interpret a numeric address read from a native struct. Zero stays zero and is checked by readers. */
export function pointerAt(address: number): Pointer {
	return address as Pointer
}

/** Copy the borrowed thread-local last-error string. Call only right after a reported failure. */
export function lastError(native: NativeSymbols): string {
	const message = native.guillotine_get_last_error()
	return message === null ? 'unknown native error' : message.toString()
}

/** Copy `len` bytes from native memory into a JS-owned buffer. */
export function copyNative(address: Pointer, offset: number, len: number): Uint8Array {
	if (len === 0) return new Uint8Array(0)
	if (address === 0) throw GuillotineError.memoryError(`Native buffer of ${len} bytes has a null pointer`)
	return new Uint8Array(toArrayBuffer(address, offset, len)).slice()
}

/** Read a native `size_t`, rejecting values JavaScript cannot index. */
export function readSize(address: Pointer, offset: number): number {
	const value = read.u64(address, offset)
	if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw GuillotineError.memoryError(`Native length ${value} exceeds Number.MAX_SAFE_INTEGER`)
	}
	return Number(value)
}

export function readPointer(address: Pointer, offset: number): Pointer {
	return read.ptr(address, offset) as Pointer
}

export function readU8(address: Pointer, offset: number): number {
	return read.u8(address, offset)
}

export function readU64(address: Pointer, offset: number): bigint {
	return read.u64(address, offset)
}

export function readCString(address: Pointer): string {
	return new CString(address).toString()
}

/** Raw address of a JS buffer, for embedding inside a native struct. */
export function addressOf(buffer: Uint8Array): Pointer {
	return ptr(buffer)
}
