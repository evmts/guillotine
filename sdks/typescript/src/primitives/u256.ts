/**
 * Represents a 256-bit unsigned integer
 */
export class U256 {
  private readonly _value: bigint;

  private constructor(value: bigint) {
    if (value < 0n) {
      throw new Error('U256 cannot be negative');
    }
    if (value >= 2n ** 256n) {
      throw new Error('Value too large for U256');
    }
    this._value = value;
  }

  /**
   * Creates a U256 from a regular number
   */
  static fromNumber(value: number): U256 {
    if (!Number.isInteger(value) || value < 0) {
      throw new Error('Value must be a non-negative integer');
    }
    return new U256(BigInt(value));
  }

  /**
   * Creates a U256 from a bigint
   */
  static fromBigInt(value: bigint): U256 {
    return new U256(value);
  }

  /**
   * Creates a U256 from a hex string
   */
  static fromHex(hex: string): U256 {
    // Remove 0x prefix if present
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    
    if (cleanHex.length === 0) {
      return U256.zero();
    }
    
    if (cleanHex.length > 64) {
      throw new Error(`Hex string too long for U256: ${cleanHex.length} characters`);
    }
    
    if (!/^[0-9a-fA-F]+$/.test(cleanHex)) {
      throw new Error('Invalid hex string: contains non-hex characters');
    }
    
    return new U256(BigInt('0x' + cleanHex));
  }

  /**
   * Creates a U256 from bytes (big-endian)
   */
  static fromBytes(bytes: Uint8Array | ArrayLike<number>): U256 {
    const byteArray = new Uint8Array(bytes);
    
    if (byteArray.length > 32) {
      throw new Error(`Too many bytes for U256: ${byteArray.length}`);
    }
    
    let value = 0n;
    for (let i = 0; i < byteArray.length; i++) {
      value = (value << 8n) + BigInt(byteArray[i] ?? 0);
    }
    
    return new U256(value);
  }

  /**
   * Creates a U256 with value 0
   */
  static zero(): U256 {
    return new U256(0n);
  }

  /**
   * Creates a U256 with value 1
   */
  static one(): U256 {
    return new U256(1n);
  }

  /**
   * Creates the maximum U256 value (2^256 - 1)
   */
  static max(): U256 {
    return new U256(2n ** 256n - 1n);
  }

  /**
   * Convenience method to create U256 from various inputs
   * @param input - Number, bigint, hex string, or byte array
   */
  static from(input: number | bigint | string | Uint8Array | ArrayLike<number>): U256 {
    if (typeof input === 'number') {
      return U256.fromNumber(input);
    }
    if (typeof input === 'bigint') {
      return U256.fromBigInt(input);
    }
    if (typeof input === 'string') {
      return U256.fromHex(input);
    }
    return U256.fromBytes(input);
  }

  /**
   * Returns the value as a bigint
   */
  toBigInt(): bigint {
    return this._value;
  }

  /**
   * Returns the value as a regular number (throws if too large)
   */
  toNumber(): number {
    if (this._value > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error('Value too large to convert to number');
    }
    return Number(this._value);
  }

  /**
   * Tries to convert to a regular number, returns null if too large
   */
  tryToNumber(): number | null {
    if (this._value > BigInt(Number.MAX_SAFE_INTEGER)) {
      return null;
    }
    return Number(this._value);
  }

  /**
   * Returns the value as a hex string with 0x prefix
   */
  toHex(): string {
    if (this._value === 0n) {
      return '0x0';
    }
    return `0x${this._value.toString(16)}`;
  }

  /**
   * Returns the value as a hex string with 0x prefix, padded to 64 characters
   */
  toHexPadded(): string {
    return `0x${this._value.toString(16).padStart(64, '0')}`;
  }

  /**
   * Returns the value as bytes (big-endian, 32 bytes)
   */
  toBytes(): Uint8Array {
    const bytes = new Uint8Array(32);
    let value = this._value;
    
    for (let i = 31; i >= 0; i--) {
      bytes[i] = Number(value & 0xFFn);
      value >>= 8n;
    }
    
    return bytes;
  }

  /**
   * Returns the value as a decimal string
   */
  toString(): string {
    return this._value.toString();
  }

  /**
   * Returns true if the value is zero
   */
  isZero(): boolean {
    return this._value === 0n;
  }

  /**
   * Returns true if two U256s are equal
   */
  equals(other: U256): boolean {
    return this._value === other._value;
  }

  /**
   * Returns true if this < other
   */
  lt(other: U256): boolean {
    return this._value < other._value;
  }

  /**
   * Returns true if this <= other
   */
  lte(other: U256): boolean {
    return this._value <= other._value;
  }

  /**
   * Returns true if this > other
   */
  gt(other: U256): boolean {
    return this._value > other._value;
  }

  /**
   * Returns true if this >= other
   */
  gte(other: U256): boolean {
    return this._value >= other._value;
  }

  /**
   * Addition with overflow checking
   */
  add(other: U256): U256 {
    const result = this._value + other._value;
    if (result >= 2n ** 256n) {
      throw new Error('Addition overflow');
    }
    return new U256(result);
  }

  /**
   * Subtraction with underflow checking
   */
  sub(other: U256): U256 {
    if (this._value < other._value) {
      throw new Error('Subtraction underflow');
    }
    return new U256(this._value - other._value);
  }

  /**
   * Multiplication with overflow checking
   */
  mul(other: U256): U256 {
    const result = this._value * other._value;
    if (result >= 2n ** 256n) {
      throw new Error('Multiplication overflow');
    }
    return new U256(result);
  }

  /**
   * Division with division by zero checking
   */
  div(other: U256): U256 {
    if (other._value === 0n) {
      throw new Error('division by zero');
    }
    return new U256(this._value / other._value);
  }

  /**
   * Modulo operation
   */
  mod(other: U256): U256 {
    if (other._value === 0n) {
      throw new Error('modulo by zero');
    }
    return new U256(this._value % other._value);
  }

  /**
   * Bitwise AND
   */
  and(other: U256): U256 {
    return new U256(this._value & other._value);
  }

  /**
   * Bitwise OR
   */
  or(other: U256): U256 {
    return new U256(this._value | other._value);
  }

  /**
   * Bitwise XOR
   */
  xor(other: U256): U256 {
    return new U256(this._value ^ other._value);
  }

  /**
   * Bitwise NOT
   */
  not(): U256 {
    return new U256((2n ** 256n - 1n) ^ this._value);
  }

  /**
   * Left shift
   */
  shl(bits: number): U256 {
    if (bits < 0 || bits >= 256) {
      throw new Error('Shift amount out of range');
    }
    const result = this._value << BigInt(bits);
    if (result >= 2n ** 256n) {
      throw new Error('Shift overflow');
    }
    return new U256(result);
  }

  /**
   * Right shift
   */
  shr(bits: number): U256 {
    if (bits < 0 || bits >= 256) {
      throw new Error('Shift amount out of range');
    }
    return new U256(this._value >> BigInt(bits));
  }

  /**
   * JSON serialization
   */
  toJSON(): string {
    return this.toHex();
  }

  /**
   * Create from JSON
   */
  static fromJSON(json: string): U256 {
    return U256.fromHex(json);
  }
}