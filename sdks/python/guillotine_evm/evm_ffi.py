"""
Bun-like Python EVM wrapper using guillotine_ffi C ABI.

This mirrors the Bun SDK API shape for parity:
- EVM(block_info)
- set_balance(address, balance)
- set_code(address, code)
- call(params)
- simulate(params)
- destroy()
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Optional, Union

from ._ffi_ffi import ffi, lib, require_ffi
from .primitives_enhanced import Address, U256, Bytes


class CallType(IntEnum):
    CALL = 0
    DELEGATECALL = 1
    STATICCALL = 2
    CREATE = 3
    CREATE2 = 4


@dataclass
class BlockInfo:
    number: int
    timestamp: int
    gas_limit: int
    coinbase: Union[str, Address]
    base_fee: int
    chain_id: int
    difficulty: int = 0
    prev_randao: bytes = b"\x00" * 32


@dataclass
class CallParams:
    caller: Union[str, Address]
    to: Union[str, Address]
    value: Union[int, U256]
    input: bytes
    gas: int
    call_type: CallType
    salt: Optional[Union[int, U256]] = None  # for CREATE2


@dataclass
class EvmResult:
    success: bool
    gas_left: int
    output: bytes
    error: Optional[str] = None


def _addr_to20(addr: Union[str, Address, None]) -> bytes:
    if addr is None:
        return b'\x00' * 20  # Zero address for None (CREATE transactions)
    if isinstance(addr, Address):
        return addr.to_bytes()
    # string hex
    return Address.from_hex(addr).to_bytes()


def _u256_to32(value: Union[int, U256]) -> bytes:
    if isinstance(value, U256):
        return value.to_bytes(byteorder="big")
    if value < 0:
        raise ValueError("U256 cannot be negative")
    return int(value).to_bytes(32, byteorder="big", signed=False)


class EVM:
    def __init__(self, block_info: BlockInfo) -> None:
        require_ffi()

        # Build BlockInfoFFI
        bi = ffi.new("BlockInfoFFI *")
        bi.number = int(block_info.number)
        bi.timestamp = int(block_info.timestamp)
        bi.gas_limit = int(block_info.gas_limit)
        coinbase = _addr_to20(block_info.coinbase)
        for i in range(20):
            bi.coinbase[i] = coinbase[i]
        bi.base_fee = int(block_info.base_fee)
        bi.chain_id = int(block_info.chain_id)
        bi.difficulty = int(block_info.difficulty)
        prev_randao = block_info.prev_randao or (b"\x00" * 32)
        if len(prev_randao) != 32:
            raise ValueError("prev_randao must be 32 bytes")
        for i in range(32):
            bi.prev_randao[i] = prev_randao[i]

        # Create EVM handle
        self._handle = lib.guillotine_evm_create(bi)
        if self._handle == ffi.NULL:
            err = ffi.string(lib.guillotine_get_last_error()).decode("utf-8")
            raise RuntimeError(f"Failed to create EVM: {err}")

        self._closed = False

    def destroy(self) -> None:
        if not self._closed and self._handle != ffi.NULL:
            lib.guillotine_evm_destroy(self._handle)
            self._handle = ffi.NULL
            self._closed = True

    def __del__(self) -> None:
        try:
            self.destroy()
        except Exception:
            pass

    # State ops
    def set_balance(self, address: Union[str, Address], balance: Union[int, U256]) -> None:
        addr20 = _addr_to20(address)
        bal32 = _u256_to32(balance)
        ok = lib.guillotine_set_balance(self._handle, addr20, bal32)
        if not ok:
            err = ffi.string(lib.guillotine_get_last_error()).decode("utf-8")
            raise RuntimeError(f"set_balance failed: {err}")

    def set_code(self, address: Union[str, Address], code: Union[bytes, Bytes]) -> None:
        addr20 = _addr_to20(address)
        data = code.to_bytes() if hasattr(code, "to_bytes") else bytes(code)
        buf = ffi.new("unsigned char[]", data)
        ok = lib.guillotine_set_code(self._handle, addr20, buf, len(data))
        if not ok:
            err = ffi.string(lib.guillotine_get_last_error()).decode("utf-8")
            raise RuntimeError(f"set_code failed: {err}")

    # Execution
    def _do_call(self, params: CallParams, simulate: bool = False) -> EvmResult:
        cp = ffi.new("CallParams *")

        caller = _addr_to20(params.caller)
        to = _addr_to20(params.to)
        val = _u256_to32(params.value)
        for i in range(20):
            cp.caller[i] = caller[i]
            cp.to[i] = to[i]
        for i in range(32):
            cp.value[i] = val[i]

        inp = params.input or b""
        inbuf = ffi.new("unsigned char[]", inp) if inp else ffi.NULL
        cp.input = inbuf
        cp.input_len = len(inp)
        cp.gas = int(params.gas)
        cp.call_type = int(params.call_type)

        if params.call_type == CallType.CREATE2:
            salt = _u256_to32(params.salt or 0)
            for i in range(32):
                cp.salt[i] = salt[i]
        else:
            for i in range(32):
                cp.salt[i] = 0

        res_ptr = lib.guillotine_simulate(self._handle, cp) if simulate else lib.guillotine_call(self._handle, cp)
        if res_ptr == ffi.NULL:
            err = ffi.string(lib.guillotine_get_last_error()).decode("utf-8")
            raise RuntimeError(f"call failed: {err}")

        try:
            success = bool(res_ptr.success)
            gas_left = int(res_ptr.gas_left)
            out_len = int(res_ptr.output_len)
            if out_len > 0 and res_ptr.output != ffi.NULL:
                output = bytes(ffi.buffer(res_ptr.output, out_len))
            else:
                output = b""
            error = None
            if not success and res_ptr.error_message != ffi.NULL:
                error = ffi.string(res_ptr.error_message).decode("utf-8")
            return EvmResult(success=success, gas_left=gas_left, output=output, error=error)
        finally:
            # Frees both output buffer and result struct
            lib.guillotine_free_result(res_ptr)

    def call(self, params: CallParams) -> EvmResult:
        return self._do_call(params, simulate=False)

    def simulate(self, params: CallParams) -> EvmResult:
        return self._do_call(params, simulate=True)
