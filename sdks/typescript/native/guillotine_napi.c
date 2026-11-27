/*
 * Zero-node-gyp Node-API (N-API v8) wrapper over Guillotine's C ABI (guillotine.h).
 * Built directly by `zig build napi` into a standalone `guillotine.node` dynamic addon
 * loadable from Node.js (>=20), Bun (>=1.1), and Deno without Python or node-gyp.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "guillotine.h"
#include "node_api_subset.h"

static bool get_bytes(napi_env env, napi_value val, const uint8_t** ptr_out, size_t* len_out) {
  bool is_ta = false;
  if (napi_is_typedarray(env, val, &is_ta) == napi_ok && is_ta) {
    napi_typedarray_type ta_type;
    size_t length = 0;
    void* data = NULL;
    if (napi_get_typedarray_info(env, val, &ta_type, &length, &data, NULL, NULL) != napi_ok) {
      return false;
    }
    if (ta_type != napi_uint8_array && ta_type != napi_uint8_clamped_array) {
      return false;
    }
    *ptr_out = (const uint8_t*)data;
    *len_out = length;
    return true;
  }
  bool is_buf = false;
  if (napi_is_buffer(env, val, &is_buf) == napi_ok && is_buf) {
    void* data = NULL;
    size_t length = 0;
    if (napi_get_buffer_info(env, val, &data, &length) != napi_ok) return false;
    *ptr_out = (const uint8_t*)data;
    *len_out = length;
    return true;
  }
  return false;
}

static bool get_fixed_bytes(napi_env env, napi_value val, uint8_t* dst, size_t expected) {
  const uint8_t* src = NULL;
  size_t len = 0;
  if (!get_bytes(env, val, &src, &len) || len != expected) {
    napi_throw_type_error(env, "ERR_INVALID_ARG", "Expected Uint8Array with exact byte length");
    return false;
  }
  memcpy(dst, src, expected);
  return true;
}

static bool get_u64(napi_env env, napi_value val, uint64_t* out) {
  napi_valuetype t;
  if (napi_typeof(env, val, &t) != napi_ok) return false;
  if (t == napi_bigint) {
    bool lossless = false;
    if (napi_get_value_bigint_uint64(env, val, out, &lossless) != napi_ok || !lossless) {
      napi_throw_type_error(env, "ERR_INVALID_ARG", "BigInt out of uint64 range");
      return false;
    }
    return true;
  }
  if (t == napi_number) {
    uint32_t v = 0;
    if (napi_get_value_uint32(env, val, &v) != napi_ok) return false;
    *out = (uint64_t)v;
    return true;
  }
  napi_throw_type_error(env, "ERR_INVALID_ARG", "Expected BigInt or uint32");
  return false;
}

static bool get_handle(napi_env env, napi_value val, EvmHandle** out) {
  uint64_t token = 0;
  if (!get_u64(env, val, &token)) return false;
  *out = (EvmHandle*)(uintptr_t)token;
  return true;
}

static bool read_le_u64(const uint8_t* p, uint64_t* out) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) {
    v = (v << 8) | (uint64_t)p[i];
  }
  *out = v;
  return true;
}

static bool unpack_block_info(napi_env env, napi_value val, BlockInfoFFI* out) {
  const uint8_t* buf = NULL;
  size_t len = 0;
  if (!get_bytes(env, val, &buf, &len) || len < 104) {
    napi_throw_type_error(env, "ERR_INVALID_ARG", "Expected 104-byte BlockInfoFFI buffer");
    return false;
  }
  memset(out, 0, sizeof(*out));
  read_le_u64(buf + 0, &out->number);
  read_le_u64(buf + 8, &out->timestamp);
  read_le_u64(buf + 16, &out->gas_limit);
  memcpy(out->coinbase, buf + 24, 20);
  read_le_u64(buf + 48, &out->base_fee);
  read_le_u64(buf + 56, &out->chain_id);
  read_le_u64(buf + 64, &out->difficulty);
  memcpy(out->prev_randao, buf + 72, 32);
  return true;
}

static napi_value make_buffer(napi_env env, const uint8_t* data, size_t len) {
  napi_value buf = NULL;
  void* dst = NULL;
  if (napi_create_buffer_copy(env, len, len > 0 ? (const void*)data : (const void*)"", &dst, &buf) != napi_ok) {
    return NULL;
  }
  return buf;
}

static napi_value convert_result(napi_env env, const EvmResult* r) {
  napi_value obj = NULL;
  if (napi_create_object(env, &obj) != napi_ok) return NULL;

  napi_value v_success = NULL, v_gas = NULL, v_output = NULL;
  napi_get_boolean(env, r->success, &v_success);
  napi_create_bigint_uint64(env, r->gas_left, &v_gas);
  v_output = make_buffer(env, r->output, r->output_len);
  napi_set_named_property(env, obj, "success", v_success);
  napi_set_named_property(env, obj, "gasLeft", v_gas);
  napi_set_named_property(env, obj, "output", v_output);

  napi_value v_err = NULL;
  if (!r->success && r->error_message != NULL && r->error_message[0] != '\0') {
    napi_create_string_utf8(env, r->error_message, NAPI_AUTO_LENGTH, &v_err);
  } else {
    napi_get_null(env, &v_err);
  }
  napi_set_named_property(env, obj, "errorMessage", v_err);

  napi_value v_logs = NULL;
  napi_create_array_with_length(env, r->logs_len, &v_logs);
  for (size_t i = 0; i < r->logs_len; i++) {
    napi_value log_obj = NULL;
    napi_create_object(env, &log_obj);
    napi_set_named_property(env, log_obj, "address", make_buffer(env, r->logs[i].address, 20));
    napi_value v_topics = NULL;
    napi_create_array_with_length(env, r->logs[i].topics_len, &v_topics);
    for (size_t t = 0; t < r->logs[i].topics_len; t++) {
      napi_set_element(env, v_topics, (uint32_t)t, make_buffer(env, r->logs[i].topics[t], 32));
    }
    napi_set_named_property(env, log_obj, "topics", v_topics);
    napi_set_named_property(env, log_obj, "data", make_buffer(env, r->logs[i].data, r->logs[i].data_len));
    napi_set_element(env, v_logs, (uint32_t)i, log_obj);
  }
  napi_set_named_property(env, obj, "logs", v_logs);

  napi_value v_sd = NULL;
  napi_create_array_with_length(env, r->selfdestructs_len, &v_sd);
  for (size_t i = 0; i < r->selfdestructs_len; i++) {
    napi_value sd_obj = NULL;
    napi_create_object(env, &sd_obj);
    napi_set_named_property(env, sd_obj, "contract", make_buffer(env, r->selfdestructs[i].contract, 20));
    napi_set_named_property(env, sd_obj, "beneficiary", make_buffer(env, r->selfdestructs[i].beneficiary, 20));
    napi_set_element(env, v_sd, (uint32_t)i, sd_obj);
  }
  napi_set_named_property(env, obj, "selfdestructs", v_sd);

  napi_value v_addrs = NULL;
  napi_create_array_with_length(env, r->accessed_addresses_len, &v_addrs);
  for (size_t i = 0; i < r->accessed_addresses_len; i++) {
    napi_set_element(env, v_addrs, (uint32_t)i, make_buffer(env, r->accessed_addresses[i], 20));
  }
  napi_set_named_property(env, obj, "accessedAddresses", v_addrs);

  napi_value v_storage = NULL;
  napi_create_array_with_length(env, r->accessed_storage_len, &v_storage);
  for (size_t i = 0; i < r->accessed_storage_len; i++) {
    napi_value st_obj = NULL;
    napi_create_object(env, &st_obj);
    napi_set_named_property(env, st_obj, "address", make_buffer(env, r->accessed_storage[i].address, 20));
    napi_set_named_property(env, st_obj, "slot", make_buffer(env, r->accessed_storage[i].slot, 32));
    napi_set_element(env, v_storage, (uint32_t)i, st_obj);
  }
  napi_set_named_property(env, obj, "accessedStorage", v_storage);

  napi_value v_created = NULL;
  if (r->has_created_address) {
    v_created = make_buffer(env, r->created_address, 20);
  } else {
    napi_get_null(env, &v_created);
  }
  napi_set_named_property(env, obj, "createdAddress", v_created);

  napi_value v_trace = NULL;
  if (r->trace_json_len > 0 && r->trace_json != NULL) {
    napi_create_string_utf8(env, (const char*)r->trace_json, r->trace_json_len, &v_trace);
  } else {
    napi_get_null(env, &v_trace);
  }
  napi_set_named_property(env, obj, "traceJson", v_trace);
  return obj;
}

static napi_value js_init(napi_env env, napi_callback_info info) {
  (void)info;
  guillotine_init();
  napi_value undef = NULL;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value js_get_last_error(napi_env env, napi_callback_info info) {
  (void)info;
  const char* msg = guillotine_get_last_error();
  napi_value out = NULL;
  napi_create_string_utf8(env, msg ? msg : "", NAPI_AUTO_LENGTH, &out);
  return out;
}

static napi_value js_create_evm(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 2) {
    napi_throw_type_error(env, "ERR_ARGS", "createEvm(blockInfoBuf, configByte[, hardforkId]) requires 2+ args");
    return NULL;
  }
  BlockInfoFFI blk;
  if (!unpack_block_info(env, argv[0], &blk)) return NULL;
  uint32_t config_byte = 0;
  if (napi_get_value_uint32(env, argv[1], &config_byte) != napi_ok) return NULL;
  int32_t fork_id = -1;
  if (argc >= 3) {
    napi_valuetype t;
    if (napi_typeof(env, argv[2], &t) == napi_ok && t == napi_number) {
      napi_get_value_int32(env, argv[2], &fork_id);
    }
  }
  EvmHandle* h = (fork_id >= 0)
    ? guillotine_evm_create_with_fork(&blk, (uint8_t)fork_id)
    : guillotine_evm_create_with_config(&blk, (uint8_t)config_byte);
  if (h == NULL) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  napi_value out = NULL;
  napi_create_bigint_uint64(env, (uint64_t)(uintptr_t)h, &out);
  return out;
}

static napi_value js_destroy_evm(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc >= 1) {
    EvmHandle* h = NULL;
    if (get_handle(env, argv[0], &h)) guillotine_evm_destroy(h);
  }
  napi_value undef = NULL;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value js_set_block_info(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  BlockInfoFFI blk;
  if (argc < 2 || !get_handle(env, argv[0], &h) || !unpack_block_info(env, argv[1], &blk)) return NULL;
  napi_value out = NULL;
  napi_get_boolean(env, guillotine_set_block_info(h, &blk), &out);
  return out;
}

static napi_value js_set_balance(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20], bal[32];
  if (argc < 3 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20) || !get_fixed_bytes(env, argv[2], bal, 32)) return NULL;
  napi_value out = NULL;
  napi_get_boolean(env, guillotine_set_balance(h, addr, bal), &out);
  return out;
}

static napi_value js_set_nonce(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20];
  uint64_t nonce = 0;
  if (argc < 3 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20) || !get_u64(env, argv[2], &nonce)) return NULL;
  napi_value out = NULL;
  napi_get_boolean(env, guillotine_set_nonce(h, addr, nonce), &out);
  return out;
}

static napi_value js_get_nonce(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20];
  if (argc < 2 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20)) return NULL;
  uint64_t nonce = 0;
  if (!guillotine_get_nonce(h, addr, &nonce)) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  napi_value out = NULL;
  napi_create_bigint_uint64(env, nonce, &out);
  return out;
}

static napi_value js_set_code(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20];
  const uint8_t* code = NULL;
  size_t code_len = 0;
  if (argc < 3 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20) || !get_bytes(env, argv[2], &code, &code_len)) return NULL;
  napi_value out = NULL;
  napi_get_boolean(env, guillotine_set_code(h, addr, code_len > 0 ? code : NULL, code_len), &out);
  return out;
}

static napi_value js_set_storage(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20], key[32], val[32];
  if (argc < 4 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20) ||
      !get_fixed_bytes(env, argv[2], key, 32) || !get_fixed_bytes(env, argv[3], val, 32)) return NULL;
  napi_value out = NULL;
  napi_get_boolean(env, guillotine_set_storage(h, addr, key, val), &out);
  return out;
}

static napi_value js_get_balance(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20], bal[32];
  if (argc < 2 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20)) return NULL;
  if (!guillotine_get_balance(h, addr, bal)) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  return make_buffer(env, bal, 32);
}

static napi_value js_get_storage(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20], key[32], val[32];
  if (argc < 3 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20) || !get_fixed_bytes(env, argv[2], key, 32)) return NULL;
  if (!guillotine_get_storage(h, addr, key, val)) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  return make_buffer(env, val, 32);
}

static napi_value js_get_code(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  EvmHandle* h = NULL;
  uint8_t addr[20];
  if (argc < 2 || !get_handle(env, argv[0], &h) || !get_fixed_bytes(env, argv[1], addr, 20)) return NULL;
  uint8_t* code = NULL;
  size_t len = 0;
  if (!guillotine_get_code(h, addr, &code, &len)) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  napi_value out = make_buffer(env, code, len);
  if (len > 0) guillotine_free_code(code, len);
  return out;
}

static napi_value run_call_impl(napi_env env, napi_callback_info info, bool is_simulate) {
  size_t argc = 8;
  napi_value argv[8];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 8) {
    napi_throw_type_error(env, "ERR_ARGS", "call/simulate requires 8 arguments");
    return NULL;
  }
  EvmHandle* h = NULL;
  CallParams p;
  memset(&p, 0, sizeof(p));
  const uint8_t* input = NULL;
  size_t input_len = 0;
  uint32_t call_type = 0;
  if (!get_handle(env, argv[0], &h) ||
      !get_fixed_bytes(env, argv[1], p.caller, 20) ||
      !get_fixed_bytes(env, argv[2], p.to, 20) ||
      !get_fixed_bytes(env, argv[3], p.value, 32) ||
      !get_bytes(env, argv[4], &input, &input_len) ||
      !get_u64(env, argv[5], &p.gas) ||
      napi_get_value_uint32(env, argv[6], &call_type) != napi_ok ||
      !get_fixed_bytes(env, argv[7], p.salt, 32)) {
    return NULL;
  }
  p.input = input_len > 0 ? input : NULL;
  p.input_len = input_len;
  p.call_type = (uint8_t)call_type;

  EvmResult* r = is_simulate ? guillotine_simulate(h, &p) : guillotine_call(h, &p);
  if (r == NULL) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  napi_value js_res = convert_result(env, r);
  guillotine_free_result(r);
  return js_res;
}

static napi_value js_call(napi_env env, napi_callback_info info) {
  return run_call_impl(env, info, false);
}

static napi_value js_simulate(napi_env env, napi_callback_info info) {
  return run_call_impl(env, info, true);
}

static napi_value js_execute_tx(napi_env env, napi_callback_info info) {
  size_t argc = 12;
  napi_value argv[12];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 12) {
    napi_throw_type_error(env, "ERR_ARGS", "executeTx requires 12 arguments");
    return NULL;
  }
  EvmHandle* h = NULL;
  TxParamsFFI tx;
  memset(&tx, 0, sizeof(tx));
  uint32_t tx_type = 0;
  if (!get_handle(env, argv[0], &h) ||
      napi_get_value_uint32(env, argv[1], &tx_type) != napi_ok ||
      !get_fixed_bytes(env, argv[2], tx.from, 20)) {
    return NULL;
  }
  tx.tx_type = (uint8_t)tx_type;

  napi_valuetype to_t;
  napi_typeof(env, argv[3], &to_t);
  if (to_t != napi_null && to_t != napi_undefined) {
    if (!get_fixed_bytes(env, argv[3], tx.to, 20)) return NULL;
    tx.has_to = true;
  }
  napi_valuetype nonce_t;
  napi_typeof(env, argv[4], &nonce_t);
  if (nonce_t != napi_null && nonce_t != napi_undefined) {
    if (!get_u64(env, argv[4], &tx.nonce)) return NULL;
    tx.has_nonce = true;
  }
  if (!get_u64(env, argv[5], &tx.gas_limit) ||
      !get_fixed_bytes(env, argv[6], tx.value, 32) ||
      !get_fixed_bytes(env, argv[7], tx.gas_price, 32)) {
    return NULL;
  }
  napi_valuetype mf_t;
  napi_typeof(env, argv[8], &mf_t);
  if (mf_t != napi_null && mf_t != napi_undefined) {
    if (!get_fixed_bytes(env, argv[8], tx.max_fee_per_gas, 32)) return NULL;
    tx.has_max_fee = true;
  }
  const uint8_t* input = NULL;
  size_t input_len = 0;
  if (!get_fixed_bytes(env, argv[9], tx.max_priority_fee_per_gas, 32) ||
      !get_bytes(env, argv[10], &input, &input_len) ||
      napi_get_value_bool(env, argv[11], &tx.disable_balance_check) != napi_ok) {
    return NULL;
  }
  tx.input = input_len > 0 ? input : NULL;
  tx.input_len = input_len;

  EvmResult* r = guillotine_execute_tx(h, &tx);
  if (r == NULL) {
    napi_value n = NULL;
    napi_get_null(env, &n);
    return n;
  }
  napi_value js_res = convert_result(env, r);
  guillotine_free_result(r);
  return js_res;
}

NAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports) {
  static const napi_property_descriptor props[] = {
    {"init", NULL, js_init, NULL, NULL, NULL, napi_default, NULL},
    {"getLastError", NULL, js_get_last_error, NULL, NULL, NULL, napi_default, NULL},
    {"createEvm", NULL, js_create_evm, NULL, NULL, NULL, napi_default, NULL},
    {"destroyEvm", NULL, js_destroy_evm, NULL, NULL, NULL, napi_default, NULL},
    {"setBlockInfo", NULL, js_set_block_info, NULL, NULL, NULL, napi_default, NULL},
    {"setBalance", NULL, js_set_balance, NULL, NULL, NULL, napi_default, NULL},
    {"setNonce", NULL, js_set_nonce, NULL, NULL, NULL, napi_default, NULL},
    {"getNonce", NULL, js_get_nonce, NULL, NULL, NULL, napi_default, NULL},
    {"setCode", NULL, js_set_code, NULL, NULL, NULL, napi_default, NULL},
    {"setStorage", NULL, js_set_storage, NULL, NULL, NULL, napi_default, NULL},
    {"getBalance", NULL, js_get_balance, NULL, NULL, NULL, napi_default, NULL},
    {"getStorage", NULL, js_get_storage, NULL, NULL, NULL, napi_default, NULL},
    {"getCode", NULL, js_get_code, NULL, NULL, NULL, napi_default, NULL},
    {"call", NULL, js_call, NULL, NULL, NULL, napi_default, NULL},
    {"simulate", NULL, js_simulate, NULL, NULL, NULL, napi_default, NULL},
    {"executeTx", NULL, js_execute_tx, NULL, NULL, NULL, napi_default, NULL},
  };
  napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
  return exports;
}
