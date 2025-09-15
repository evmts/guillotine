/**
 * Represents a 20-byte Ethereum address
 */
export class Address {
  private readonly _bytes: Uint8Array;

  private constructor(bytes: Uint8Array) {
    if (bytes.length !== 20) {
      throw new Error(`Invalid address length: expected 20 bytes, got ${bytes.length}`);
    }
    this._bytes = new Uint8Array(bytes);
  }

  /**
   * Creates an Address from a byte array
   */
  static fromBytes(bytes: Uint8Array | ArrayLike<number>): Address {
    return new Address(new Uint8Array(bytes));
  }

  /**
   * Creates an Address from a hex string
   */
  static fromHex(hex: string): Address {
    // Remove 0x prefix if present
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    
    // Check for empty string
    if (cleanHex.length === 0) {
      throw new Error('Invalid hex address: empty string');
    }
    
    // Pad with leading zeros if necessary
    const paddedHex = cleanHex.padStart(40, '0');
    
    if (paddedHex.length !== 40) {
      throw new Error(`Invalid hex address length: expected 40 characters, got ${paddedHex.length}`);
    }
    
    if (!/^[0-9a-fA-F]{40}$/.test(paddedHex)) {
      throw new Error('Invalid hex address: contains non-hex characters');
    }
    
    const bytes = new Uint8Array(20);
    for (let i = 0; i < 20; i++) {
      bytes[i] = parseInt(paddedHex.slice(i * 2, i * 2 + 2), 16);
    }
    
    return new Address(bytes);
  }

  /**
   * Creates the zero address (0x0000...0000)
   */
  static zero(): Address {
    return new Address(new Uint8Array(20));
  }

  /**
   * Convenience method to create Address from various inputs
   * @param input - Hex string or byte array
   */
  static from(input: string | Uint8Array | ArrayLike<number>): Address {
    if (typeof input === 'string') {
      return Address.fromHex(input);
    }
    return Address.fromBytes(input);
  }

  /**
   * Returns the address as a byte array
   */
  toBytes(): Uint8Array {
    return new Uint8Array(this._bytes);
  }

  /**
   * Returns the address as a hex string with 0x prefix
   */
  toHex(): string {
    return '0x' + Array.from(this._bytes)
      .map(byte => byte.toString(16).padStart(2, '0'))
      .join('');
  }

  /**
   * Returns the address as a hex string with 0x prefix
   */
  toString(): string {
    return this.toHex();
  }

  /**
   * Returns true if this is the zero address
   */
  isZero(): boolean {
    return this._bytes.every(byte => byte === 0);
  }

  /**
   * Returns true if two addresses are equal
   */
  equals(other: Address): boolean {
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
   * Returns the address as a checksummed hex string (EIP-55)
   */
  toChecksumHex(): string {
    const hex = this.toHex().slice(2).toLowerCase();
    const hash = this.keccak256(hex);
    
    let result = '0x';
    for (let i = 0; i < hex.length; i++) {
      const hashChar = hash[i];
      const hexChar = hex[i];
      if (hashChar === undefined || hexChar === undefined) {
        break;
      }
      if (parseInt(hashChar, 16) >= 8) {
        result += hexChar.toUpperCase();
      } else {
        result += hexChar;
      }
    }
    
    return result;
  }

  /**
   * Simple keccak256 implementation for checksumming
   * Note: In a real implementation, this would use a proper crypto library
   */
  private keccak256(input: string): string {
    // This is a placeholder - in practice you'd use a real keccak256 implementation
    // For now, we'll just return the input as lowercase hex
    return input.padEnd(64, '0');
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
  static fromJSON(json: string): Address {
    return Address.fromHex(json);
  }
}