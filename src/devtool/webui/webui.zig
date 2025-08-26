//! WebUI - A modern web UI library for Zig
//! This module combines all WebUI functionality into a single interface

const std = @import("std");
const builtin = @import("builtin");

const Webui = @This();

// The window handle is the only field of this struct
window_handle: usize,

// Import modules
const types = @import("types.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");
const binding_mod = @import("binding.zig");
const file_handler_mod = @import("file_handler.zig");
const javascript_mod = @import("javascript.zig");
const config_mod = @import("config.zig");

// Re-export all types
pub const WebUIError = types.WebUIError;
pub const WebUIErrorInfo = types.WebUIErrorInfo;
pub const Browser = types.Browser;
pub const Runtime = types.Runtime;
pub const EventKind = types.EventKind;
pub const Config = types.Config;
pub const WEBUI_VERSION = types.WEBUI_VERSION;
pub const WEBUI_MAX_IDS = types.WEBUI_MAX_IDS;
pub const WEBUI_MAX_ARG = types.WEBUI_MAX_ARG;

// Re-export Event
pub const Event = event_mod.Event;

// Re-export functions from window module
pub const new_window = window_mod.new_window;
pub const new_window_with_id = window_mod.new_window_with_id;
pub const get_new_window_id = window_mod.get_new_window_id;
pub const get_best_browser = window_mod.get_best_browser;
pub const show = window_mod.show;
pub const show_browser = window_mod.show_browser;
pub const start_server = window_mod.start_server;
pub const show_wv = window_mod.show_wv;
pub const set_kiosk = window_mod.set_kiosk;
pub const close = window_mod.close;
pub const minimize = window_mod.minimize;
pub const maximize = window_mod.maximize;
pub const destroy = window_mod.destroy;
pub const is_shown = window_mod.is_shown;
pub const set_hide = window_mod.set_hide;
pub const set_size = window_mod.set_size;
pub const set_minimum_size = window_mod.set_minimum_size;
pub const set_position = window_mod.set_position;
pub const set_center = window_mod.set_center;
pub const set_profile = window_mod.set_profile;
pub const delete_profile = window_mod.delete_profile;
pub const get_parent_process_id = window_mod.get_parent_process_id;
pub const get_child_process_id = window_mod.get_child_process_id;
pub const win32_get_hwnd = window_mod.win32_get_hwnd;
pub const set_icon = window_mod.set_icon;
pub const set_public = window_mod.set_public;
pub const get_port = window_mod.get_port;
pub const set_port = window_mod.set_port;
pub const get_url = window_mod.get_url;
pub const navigate = window_mod.navigate;
pub const set_frameless = window_mod.set_frameless;
pub const set_transparent = window_mod.set_transparent;
pub const set_resizable = window_mod.set_resizable;
pub const set_high_contrast = window_mod.set_high_contrast;
pub const set_custom_parameters = window_mod.set_custom_parameters;
pub const wait = window_mod.wait;
pub const exit = window_mod.exit;
pub const clean = window_mod.clean;
pub const delete_all_profiles = window_mod.delete_all_profiles;
pub const get_free_port = window_mod.get_free_port;
pub const open_url = window_mod.open_url;
pub const is_high_contrast = window_mod.is_high_contrast;

// Re-export functions from binding module
pub const bind = binding_mod.bind;
pub const set_context = binding_mod.set_context;
pub const interface_bind = binding_mod.interface_bind;
pub const interface_set_response = binding_mod.interface_set_response;
pub const binding = binding_mod.binding;

// Re-export functions from file_handler module
pub const set_root_folder = file_handler_mod.set_root_folder;
pub const set_browser_folder = file_handler_mod.set_browser_folder;
pub const set_file_handler = file_handler_mod.set_file_handler;
pub const set_file_handler_window = file_handler_mod.set_file_handler_window;
pub const interface_set_response_file_handler = file_handler_mod.interface_set_response_file_handler;
pub const set_default_root_folder = file_handler_mod.set_default_root_folder;

// Re-export functions from javascript module
pub const run = javascript_mod.run;
pub const script = javascript_mod.script;
pub const set_runtime = javascript_mod.set_runtime;
pub const send_raw = javascript_mod.send_raw;
pub const interface_get_string_at = javascript_mod.interface_get_string_at;
pub const interface_get_int_at = javascript_mod.interface_get_int_at;
pub const interface_get_float_at = javascript_mod.interface_get_float_at;
pub const interface_get_bool_at = javascript_mod.interface_get_bool_at;
pub const interface_get_size_at = javascript_mod.interface_get_size_at;
pub const interface_show_client = javascript_mod.interface_show_client;
pub const interface_close_client = javascript_mod.interface_close_client;
pub const interface_send_raw_client = javascript_mod.interface_send_raw_client;
pub const interface_navigate_client = javascript_mod.interface_navigate_client;
pub const interface_run_client = javascript_mod.interface_run_client;
pub const interface_script_client = javascript_mod.interface_script_client;

// Re-export functions from config module
pub const set_event_blocking = config_mod.set_event_blocking;
pub const set_proxy = config_mod.set_proxy;
pub const interface_get_window_id = config_mod.interface_get_window_id;
pub const set_config = config_mod.set_config;
pub const set_timeout = config_mod.set_timeout;
pub const browser_exist = config_mod.browser_exist;
pub const interface_is_app_running = config_mod.interface_is_app_running;