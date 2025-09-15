/**
 * Represents a 32-byte hash value
 */
export class Hash {
  private readonly _bytes: Uint8Array;

  private constructor(bytes: Uint8Array) {
    if (bytes.length !== 32) {
      throw new Error(`Invalid hash length: expected 32 bytes, got ${bytes.length}`);
    }
    this._bytes = new Uint8Array(bytes);
  }

  /**
   * Creates a Hash from a byte array
   */
  static fromBytes(bytes: Uint8Array | ArrayLike<number>): Hash {
    return new Hash(new Uint8Array(bytes));
  }

  /**
   * Creates a Hash from a hex string
   */
  static fromHex(hex: string): Hash {
    // Remove 0x prefix if present
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    
    // Pad with leading zeros if necessary
    const paddedHex = cleanHex.padStart(64, '0');
    
    if (paddedHex.length !== 64) {
      throw new Error(`Invalid hex hash length: expected 64 characters, got ${paddedHex.length}`);
    }
    
    if (!/^[0-9a-fA-F]{64}$/.test(paddedHex)) {
      throw new Error('Invalid hex hash: contains non-hex characters');
    }
    
    const bytes = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      bytes[i] = parseInt(paddedHex.slice(i * 2, i * 2 + 2), 16);
    }
    
    return new Hash(bytes);
  }

  /**
   * Creates the zero hash (0x0000...0000)
   */
  static zero(): Hash {
    return new Hash(new Uint8Array(32));
  }

  /**
   * Creates a hash from a string (UTF-8 encoded, then hashed)
   * Note: This is a simple implementation - in practice you'd use a proper hash function
   */
  static fromString(str: string): Hash {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(str);
    
    // Simple hash - in practice you'd use keccak256 or similar
    const hash = new Uint8Array(32);
    for (let i = 0; i < bytes.length; i++) {
      const index = i % 32;
      const byteValue = bytes[i];
      if (byteValue !== undefined) {
        hash[index] = (hash[index] ?? 0) ^ byteValue;
      }
    }
    
    return new Hash(hash);
  }

  /**
   * Returns the hash as a byte array
   */
  toBytes(): Uint8Array {
    return new Uint8Array(this._bytes);
  }

  /**
   * Returns the hash as a hex string with 0x prefix
   */
  toHex(): string {
    return '0x' + Array.from(this._bytes)
      .map(byte => byte.toString(16).padStart(2, '0'))
      .join('');
  }

  /**
   * Returns the hash as a hex string with 0x prefix
   */
  toString(): string {
    return this.toHex();
  }

  /**
   * Returns true if this is the zero hash
   */
  isZero(): boolean {
    return this._bytes.every(byte => byte === 0);
  }

  /**
   * Returns true if two hashes are equal
   */
  equals(other: Hash): boolean {
    if (this._bytes.length !== other._bytes.length) {
      return false;
    }
    
    for (let i = 0; i < this._bytes.length; i++) {
      if (this._bytes[i] !== other._bytes[i]) {
        return false;
      }
    }
    
    return true;
  }

  /**
   * Returns the first n bytes of the hash
   */
  slice(start: number, end?: number): Uint8Array {
    return this._bytes.slice(start, end);
  }

  /**
   * Returns a specific byte at the given index
   */
  at(index: number): number {
    if (index < 0 || index >= 32) {
      throw new Error(`Index out of bounds: ${index}`);
    }
    const value = this._bytes[index];
    if (value === undefined) {
      throw new Error(`Unexpected undefined value at index ${index}`);
    }
    return value;
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
  static fromJSON(json: string): Hash {
    return Hash.fromHex(json);
  }
}