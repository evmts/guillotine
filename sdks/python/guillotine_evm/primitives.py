"""
Ethereum primitive types for Guillotine EVM Python bindings.

This module provides Python wrappers for core Ethereum types like Address, U256, and Hash.
"""

import re
from typing import Union, Optional
from .exceptions import InvalidAddressError, InvalidHashError
from ._ffi_ffi import lib, ffi


class Address:
    """
    Ethereum address (20 bytes).
    
    Represents a 20-byte Ethereum address with validation and utility methods.
    """
    
    ZERO: 'Address'
    _ADDRESS_PATTERN = re.compile(r'^0x[0-9a-fA-F]{40}$')
    
    def __init__(self, data: bytes) -> None:
        if len(data) != 20:
            raise InvalidAddressError(f"Address must be exactly 20 bytes, got {len(data)}")
        self._data = data
    
    @classmethod
    def from_hex(cls, hex_str: str) -> 'Address':
        """Create an address from a hex string."""
        if not hex_str.startswith('0x'):
            hex_str = '0x' + hex_str
        
        if not cls._ADDRESS_PATTERN.match(hex_str):
            raise InvalidAddressError(f"Invalid address format: {hex_str}")
        
        try:
            data = bytes.fromhex(hex_str[2:])
            return cls(data)
        except ValueError as e:
            raise InvalidAddressError(f"Invalid hex address: {hex_str}") from e
    
    @classmethod
    def from_bytes(cls, data: bytes) -> 'Address':
        """Create an address from raw bytes."""
        return cls(data)
    
    @classmethod
    def zero(cls) -> 'Address':
        """Create a zero address (0x0000...0000)."""
        return cls(b'\x00' * 20)
    
    def to_hex(self) -> str:
        """Convert to hex string with 0x prefix."""
        return '0x' + self._data.hex()
    
    def to_bytes(self) -> bytes:
        """Get the raw bytes."""
        return self._data
    
    def is_zero(self) -> bool:
        """Check if this is the zero address."""
        return self._data == b'\x00' * 20
    
    def __str__(self) -> str:
        return self.to_hex()
    
    def __repr__(self) -> str:
        return f"Address('{self.to_hex()}')"
    
    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Address):
            return False
        return self._data == other._data
    
    def __hash__(self) -> int:
        return hash(self._data)


# Initialize the zero address
Address.ZERO = Address.zero()


class U256:
    """
    256-bit unsigned integer for Ethereum.
    
    Represents a 256-bit unsigned integer with arithmetic operations and conversions.
    """
    
    MAX_VALUE = (1 << 256) - 1
    ZERO: 'U256'
    ONE: 'U256'
    
    def __init__(self, value: Union[int, str, bytes]) -> None:
        if isinstance(value, int):
            if value < 0 or value > self.MAX_VALUE:
                raise ValueError(f"U256 value must be between 0 and {self.MAX_VALUE}")
            self._value = value
        elif isinstance(value, str):
            if value.startswith('0x'):
                self._value = int(value, 16)
            else:
                self._value = int(value)
            if self._value < 0 or self._value > self.MAX_VALUE:
                raise ValueError(f"U256 value must be between 0 and {self.MAX_VALUE}")
        elif isinstance(value, bytes):
            if len(value) > 32:
                raise ValueError("U256 bytes must be at most 32 bytes")
            # Convert from big-endian bytes
            self._value = int.from_bytes(value, byteorder='big')
        else:
            raise TypeError(f"Unsupported type for U256: {type(value)}")
    
    @classmethod
    def from_int(cls, value: int) -> 'U256':
        """Create U256 from integer."""
        return cls(value)
    
    @classmethod
    def from_hex(cls, hex_str: str) -> 'U256':
        """Create U256 from hex string."""
        return cls(hex_str)
    
    @classmethod
    def from_bytes(cls, data: bytes, byteorder: str = 'big') -> 'U256':
        """Create U256 from bytes."""
        if byteorder == 'big':
            return cls(data)
        elif byteorder == 'little':
            return cls(int.from_bytes(data, byteorder='little'))
        else:
            raise ValueError("byteorder must be 'big' or 'little'")
    
    @classmethod
    def zero(cls) -> 'U256':
        """Create a zero value."""
        return cls(0)
    
    @classmethod
    def one(cls) -> 'U256':
        """Create a one value."""
        return cls(1)
    
    def to_int(self) -> int:
        """Convert to Python int."""
        return self._value
    
    def to_hex(self) -> str:
        """Convert to hex string with 0x prefix."""
        return f"0x{self._value:064x}"
    
    def to_bytes(self, byteorder: str = 'big') -> bytes:
        """Convert to bytes."""
        return self._value.to_bytes(32, byteorder=byteorder)
    
    def is_zero(self) -> bool:
        """Check if value is zero."""
        return self._value == 0
    
    def __str__(self) -> str:
        return str(self._value)
    
    def __repr__(self) -> str:
        return f"U256({self._value})"
    
    def __int__(self) -> int:
        return self._value
    
    def __eq__(self, other: object) -> bool:
        if isinstance(other, U256):
            return self._value == other._value
        elif isinstance(other, int):
            return self._value == other
        return False
    
    def __lt__(self, other: Union['U256', int]) -> bool:
        if isinstance(other, U256):
            return self._value < other._value
        elif isinstance(other, int):
            return self._value < other
        return NotImplemented
    
    def __le__(self, other: Union['U256', int]) -> bool:
        return self < other or self == other
    
    def __gt__(self, other: Union['U256', int]) -> bool:
        return not self <= other
    
    def __ge__(self, other: Union['U256', int]) -> bool:
        return not self < other
    
    def __add__(self, other: Union['U256', int]) -> 'U256':
        if isinstance(other, U256):
            result = (self._value + other._value) % (1 << 256)
        elif isinstance(other, int):
            result = (self._value + other) % (1 << 256)
        else:
            return NotImplemented
        return U256(result)
    
    def __sub__(self, other: Union['U256', int]) -> 'U256':
        if isinstance(other, U256):
            result = (self._value - other._value) % (1 << 256)
        elif isinstance(other, int):
            result = (self._value - other) % (1 << 256)
        else:
            return NotImplemented
        return U256(result)
    
    def __mul__(self, other: Union['U256', int]) -> 'U256':
        if isinstance(other, U256):
            result = (self._value * other._value) % (1 << 256)
        elif isinstance(other, int):
            result = (self._value * other) % (1 << 256)
        else:
            return NotImplemented
        return U256(result)
    
    def __floordiv__(self, other: Union['U256', int]) -> 'U256':
        if isinstance(other, U256):
            if other._value == 0:
                raise ZeroDivisionError("Division by zero")
            result = self._value // other._value
        elif isinstance(other, int):
            if other == 0:
                raise ZeroDivisionError("Division by zero")
            result = self._value // other
        else:
            return NotImplemented
        return U256(result)
    
    def __mod__(self, other: Union['U256', int]) -> 'U256':
        if isinstance(other, U256):
            if other._value == 0:
                raise ZeroDivisionError("Modulo by zero")
            result = self._value % other._value
        elif isinstance(other, int):
            if other == 0:
                raise ZeroDivisionError("Modulo by zero")
            result = self._value % other
        else:
            return NotImplemented
        return U256(result)
    
    def __hash__(self) -> int:
        return hash(self._value)


# Initialize constants
U256.ZERO = U256.zero()
U256.ONE = U256.one()


class Hash:
    """
    256-bit hash (32 bytes).
    
    Represents a 32-byte hash value commonly used in Ethereum.
    """
    
    ZERO: 'Hash'
    _HASH_PATTERN = re.compile(r'^0x[0-9a-fA-F]{64}$')
    
    def __init__(self, data: bytes) -> None:
        if len(data) != 32:
            raise InvalidHashError(f"Hash must be exactly 32 bytes, got {len(data)}")
        self._data = data
    
    @classmethod
    def from_hex(cls, hex_str: str) -> 'Hash':
        """Create a hash from a hex string."""
        if not hex_str.startswith('0x'):
            hex_str = '0x' + hex_str
        
        if not cls._HASH_PATTERN.match(hex_str):
            raise InvalidHashError(f"Invalid hash format: {hex_str}")
        
        try:
            data = bytes.fromhex(hex_str[2:])
            return cls(data)
        except ValueError as e:
            raise InvalidHashError(f"Invalid hex hash: {hex_str}") from e
    
    @classmethod
    def from_bytes(cls, data: bytes) -> 'Hash':
        """Create a hash from raw bytes."""
        return cls(data)
    
    @classmethod
    def zero(cls) -> 'Hash':
        """Create a zero hash (0x0000...0000)."""
        return cls(b'\x00' * 32)
    
    def to_hex(self) -> str:
        """Convert to hex string with 0x prefix."""
        return '0x' + self._data.hex()
    
    def to_bytes(self) -> bytes:
        """Get the raw bytes."""
        return self._data
    
    def is_zero(self) -> bool:
        """Check if this is the zero hash."""
        return self._data == b'\x00' * 32
    
    def __str__(self) -> str:
        return self.to_hex()
    
    def __repr__(self) -> str:
        return f"Hash('{self.to_hex()}')"
    
    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Hash):
            return False
        return self._data == other._data
    
    def __hash__(self) -> int:
        return hash(self._data)


# Initialize the zero hash
Hash.ZERO = Hash.zero()


class Bytes:
    """
    Variable-length byte array.
    
    Represents arbitrary-length byte data with utility methods.
    """
    
    EMPTY: 'Bytes'
    
    def __init__(self, data: bytes) -> None:
        self._data = data
    
    @classmethod
    def from_hex(cls, hex_str: str) -> 'Bytes':
        """Create bytes from a hex string."""
        if hex_str.startswith('0x'):
            hex_str = hex_str[2:]
        
        if len(hex_str) % 2 != 0:
            hex_str = '0' + hex_str
        
        try:
            data = bytes.fromhex(hex_str)
            return cls(data)
        except ValueError as e:
            raise ValueError(f"Invalid hex string: {hex_str}") from e
    
    @classmethod
    def from_bytes(cls, data: bytes) -> 'Bytes':
        """Create bytes from raw bytes."""
        return cls(data)
    
    @classmethod
    def empty(cls) -> 'Bytes':
        """Create empty bytes."""
        return cls(b'')
    
    def to_hex(self) -> str:
        """Convert to hex string with 0x prefix."""
        return '0x' + self._data.hex()
    
    def to_bytes(self) -> bytes:
        """Get the raw bytes."""
        return self._data
    
    def is_empty(self) -> bool:
        """Check if bytes are empty."""
        return len(self._data) == 0
    
    def __len__(self) -> int:
        return len(self._data)
    
    def __str__(self) -> str:
        return self.to_hex()
    
    def __repr__(self) -> str:
        return f"Bytes('{self.to_hex()}')"
    
    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Bytes):
            return False
        return self._data == other._data
    
    def __hash__(self) -> int:
        return hash(self._data)


# Initialize empty bytes
Bytes.EMPTY = Bytes.empty()