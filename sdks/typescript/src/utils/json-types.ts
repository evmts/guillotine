/**
 * JSON Serialization Types
 * 
 * Converts types to/from their JSON representation
 */

/**
 * Converts a type to its JSON-serialized form
 * - bigint, Uint8Array, Date, Map, Set → string
 * - undefined → never
 * - Objects with toJSON method use their return type
 * - Arrays and objects are recursively converted
 */
export type Jsonified<T> = T extends string | number | boolean | null
  ? T
  : T extends undefined
  ? never
  : T extends { toJSON(): infer R }
  ? R
  : T extends bigint | Uint8Array | ArrayBuffer | Date | Map<unknown, unknown> | Set<unknown>
  ? string
  : T extends Array<infer U>
  ? Jsonified<U>[]
  : T extends object
  ? { [K in keyof T]: Jsonified<T[K]> }
  : never;

/**
 * Converts a JSON-serialized type back to its original form
 * Requires runtime conversion logic to actually transform values
 */
export type FromJson<J, T> = T extends string | number | boolean | null
  ? T
  : T extends undefined
  ? never
  : T extends bigint | Uint8Array | ArrayBuffer | Date | Map<infer _K, infer _V> | Set<infer _U>
  ? J extends string ? T : never
  : T extends Array<infer U>
  ? J extends Array<infer JU> ? FromJson<JU, U>[] : never
  : T extends object
  ? J extends object ? { [K in keyof T]: K extends keyof J ? FromJson<J[K], T[K]> : never } : never
  : never;