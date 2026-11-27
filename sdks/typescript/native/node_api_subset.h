#ifndef GUILLOTINE_NODE_API_SUBSET_H
#define GUILLOTINE_NODE_API_SUBSET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define NAPI_MODULE_EXPORT __declspec(dllexport)
#else
#define NAPI_MODULE_EXPORT __attribute__((visibility("default")))
#endif

typedef struct napi_env__* napi_env;
typedef struct napi_value__* napi_value;
typedef struct napi_callback_info__* napi_callback_info;

typedef enum {
  napi_ok = 0,
  napi_invalid_arg,
  napi_object_expected,
  napi_string_expected,
  napi_name_expected,
  napi_function_expected,
  napi_number_expected,
  napi_boolean_expected,
  napi_array_expected,
  napi_generic_failure,
  napi_pending_exception,
  napi_cancelled,
  napi_escape_called_twice,
  napi_handle_scope_mismatch,
  napi_callback_scope_mismatch,
  napi_queue_full,
  napi_closing,
  napi_bigint_expected,
  napi_date_expected,
  napi_arraybuffer_expected,
  napi_detachable_arraybuffer_expected,
  napi_would_deadlock,
} napi_status;

typedef enum {
  napi_default = 0,
  napi_writable = 1 << 0,
  napi_enumerable = 1 << 1,
  napi_configurable = 1 << 2,
  napi_static = 1 << 10,
} napi_property_attributes;

typedef enum {
  napi_undefined,
  napi_null,
  napi_boolean,
  napi_number,
  napi_string,
  napi_symbol,
  napi_object,
  napi_function,
  napi_external,
  napi_bigint,
} napi_valuetype;

typedef enum {
  napi_int8_array,
  napi_uint8_array,
  napi_uint8_clamped_array,
  napi_int16_array,
  napi_uint16_array,
  napi_int32_array,
  napi_uint32_array,
  napi_float32_array,
  napi_float64_array,
  napi_bigint64_array,
  napi_biguint64_array,
} napi_typedarray_type;

typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);

typedef struct {
  const char* utf8name;
  napi_value name;
  napi_callback method;
  napi_callback getter;
  napi_callback setter;
  napi_value value;
  napi_property_attributes attributes;
  void* data;
} napi_property_descriptor;

#define NAPI_AUTO_LENGTH SIZE_MAX

extern napi_status napi_get_cb_info(napi_env env, napi_callback_info cbinfo, size_t* argc, napi_value* argv, napi_value* this_arg, void** data);
extern napi_status napi_typeof(napi_env env, napi_value value, napi_valuetype* result);
extern napi_status napi_get_value_int32(napi_env env, napi_value value, int32_t* result);
extern napi_status napi_get_value_uint32(napi_env env, napi_value value, uint32_t* result);
extern napi_status napi_get_value_bool(napi_env env, napi_value value, bool* result);
extern napi_status napi_get_value_bigint_uint64(napi_env env, napi_value value, uint64_t* result, bool* lossless);
extern napi_status napi_is_typedarray(napi_env env, napi_value value, bool* result);
extern napi_status napi_get_typedarray_info(napi_env env, napi_value typedarray, napi_typedarray_type* type, size_t* length, void** data, napi_value* arraybuffer, size_t* byte_offset);
extern napi_status napi_is_buffer(napi_env env, napi_value value, bool* result);
extern napi_status napi_get_buffer_info(napi_env env, napi_value value, void** data, size_t* length);
extern napi_status napi_create_object(napi_env env, napi_value* result);
extern napi_status napi_create_array_with_length(napi_env env, size_t length, napi_value* result);
extern napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value);
extern napi_status napi_set_named_property(napi_env env, napi_value object, const char* utf8name, napi_value value);
extern napi_status napi_get_boolean(napi_env env, bool value, napi_value* result);
extern napi_status napi_create_bigint_uint64(napi_env env, uint64_t value, napi_value* result);
extern napi_status napi_create_string_utf8(napi_env env, const char* str, size_t length, napi_value* result);
extern napi_status napi_get_null(napi_env env, napi_value* result);
extern napi_status napi_get_undefined(napi_env env, napi_value* result);
extern napi_status napi_create_buffer_copy(napi_env env, size_t length, const void* data, void** result_data, napi_value* result);
extern napi_status napi_define_properties(napi_env env, napi_value object, size_t property_count, const napi_property_descriptor* properties);
extern napi_status napi_throw_error(napi_env env, const char* code, const char* msg);
extern napi_status napi_throw_type_error(napi_env env, const char* code, const char* msg);

#endif
