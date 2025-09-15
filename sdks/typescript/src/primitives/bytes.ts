/**
 * Represents a variable-length byte array
 */
export class Bytes {
  private readonly _data: Uint8Array;

  private constructor(data: Uint8Array) {
    this._data = new Uint8Array(data);
  }

  /**
   * Creates Bytes from a byte array
   */
  static fromBytes(data: Uint8Array | ArrayLike<number>): Bytes {
    return new Bytes(new Uint8Array(data));
  }

  /**
   * Creates Bytes from a hex string
   */
  static fromHex(hex: string): Bytes {
    // Remove 0x prefix if present
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    
    // Handle empty hex
    if (cleanHex.length === 0) {
      return new Bytes(new Uint8Array(0));
    }
    
    // Pad with leading zero if odd length
    const paddedHex = cleanHex.length % 2 === 0 ? cleanHex : '0' + cleanHex;
    
    if (!/^[0-9a-fA-F]*$/.test(paddedHex)) {
      throw new Error('Invalid hex bytes: contains non-hex characters');
    }
    
    const bytes = new Uint8Array(paddedHex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(paddedHex.slice(i * 2, i * 2 + 2), 16);
    }
    
    return new Bytes(bytes);
  }

  /**
   * Creates Bytes from a string (UTF-8 encoded)
   */
  static fromString(str: string): Bytes {
    const encoder = new TextEncoder();
    return new Bytes(encoder.encode(str));
  }

  /**
   * Creates empty Bytes
   */
  static empty(): Bytes {
    return new Bytes(new Uint8Array(0));
  }

  /**
   * Convenience method to create Bytes from various inputs
   * @param input - Hex string, byte array, or string
   */
  static from(input: string | Uint8Array | ArrayLike<number>): Bytes {
    if (typeof input === 'string') {
      // If it starts with 0x or contains only hex chars, treat as hex
      if (input.startsWith('0x') || /^[0-9a-fA-F]+$/.test(input)) {
        return Bytes.fromHex(input);
      }
      // Otherwise treat as UTF-8 string
      return Bytes.fromString(input);
    }
    return Bytes.fromBytes(input);
  }

  /**
   * Creates Bytes with the specified length, filled with zeros
   */
  static zeros(length: number): Bytes {
    if (length < 0) {
      throw new Error('Length cannot be negative');
    }
    return new Bytes(new Uint8Array(length));
  }

  /**
   * Creates Bytes with the specified length, filled with the given value
   */
  static filled(length: number, value: number): Bytes {
    if (length < 0) {
      throw new Error('Length cannot be negative');
    }
    if (value < 0 || value > 255) {
      throw new Error('Value must be between 0 and 255');
    }
    return new Bytes(new Uint8Array(length).fill(value));
  }

  /**
   * Returns a copy of the underlying byte data
   */
  toBytes(): Uint8Array {
    return new Uint8Array(this._data);
  }

  /**
   * Returns the length of the byte array
   */
  length(): number {
    return this._data.length;
  }

  /**
   * Returns true if the byte array is empty
   */
  isEmpty(): boolean {
    return this._data.length === 0;
  }

  /**
   * Returns the bytes as a hex string with 0x prefix
   */
  toHex(): string {
    if (this._data.length === 0) {
      return '0x';
    }
    return '0x' + Array.from(this._data)
      .map(byte => byte.toString(16).padStart(2, '0'))
      .join('');
  }

  /**
   * Returns the bytes as a UTF-8 decoded string
   */
  toString(): string {
    const decoder = new TextDecoder();
    return decoder.decode(this._data);
  }

  /**
   * Returns true if two Bytes are equal
   */
  equals(other: Bytes): boolean {
    if (this._data.length !== other._data.length) {
      return false;
    }
    
    for (let i = 0; i < this._data.length; i++) {
      if (this._data[i] !== other._data[i]) {
        return false;
      }
    }
    
    return true;
  }

  /**
   * Concatenates this Bytes with another Bytes
   */
  concat(other: Bytes): Bytes {
    const combined = new Uint8Array(this._data.length + other._data.length);
    combined.set(this._data, 0);
    combined.set(other._data, this._data.length);
    return new Bytes(combined);
  }

  /**
   * Returns a slice of the bytes
   */
  slice(start: number, end?: number): Bytes {
    if (start < 0 || start > this._data.length) {
      throw new Error(`Start index out of bounds: ${start}`);
    }
    
    const actualEnd = end ?? this._data.length;
    if (actualEnd < start || actualEnd > this._data.length) {
      throw new Error(`End index out of bounds: ${actualEnd}`);
    }
    
    return new Bytes(this._data.slice(start, actualEnd));
  }

  /**
   * Returns a specific byte at the given index
   */
  at(index: number): number {
    if (index < 0 || index >= this._data.length) {
      throw new Error(`Index out of bounds: ${index}`);
    }
    const value = this._data[index];
    if (value === undefined) {
      throw new Error(`Unexpected undefined value at index ${index}`);
    }
    return value;
  }

  /**
   * Sets a specific byte at the given index (returns new Bytes)
   */
  setAt(index: number, value: number): Bytes {
    if (index < 0 || index >= this._data.length) {
      throw new Error(`Index out of bounds: ${index}`);
    }
    if (value < 0 || value > 255) {
      throw new Error('Value must be between 0 and 255');
    }
    
    const newData = new Uint8Array(this._data);
    newData[index] = value;
    return new Bytes(newData);
  }

  /**
   * Pads the bytes to the specified length with zeros on the left
   */
  padStart(targetLength: number): Bytes {
    if (targetLength <= this._data.length) {
      return new Bytes(this._data);
    }
    
    const padded = new Uint8Array(targetLength);
    padded.set(this._data, targetLength - this._data.length);
    return new Bytes(padded);
  }

  /**
   * Pads the bytes to the specified length with zeros on the right
   */
  padEnd(targetLength: number): Bytes {
    if (targetLength <= this._data.length) {
      return new Bytes(this._data);
    }
    
    const padded = new Uint8Array(targetLength);
    padded.set(this._data, 0);
    return new Bytes(padded);
  }

  /**
   * Finds the index of the first occurrence of the given byte
   */
  indexOf(value: number): number {
    if (value < 0 || value > 255) {
      throw new Error('Value must be between 0 and 255');
    }
    return this._data.indexOf(value);
  }

  /**
   * Returns true if the bytes contain the given value
   */
  includes(value: number): boolean {
    return this.indexOf(value) !== -1;
  }

  /**
   * Reverses the byte order (returns new Bytes)
   */
  reverse(): Bytes {
    const reversed = new Uint8Array(this._data);
    reversed.reverse();
    return new Bytes(reversed);
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
  static fromJSON(json: string): Bytes {
    return Bytes.fromHex(json);
  }
}