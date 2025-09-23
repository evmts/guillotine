const std = @import("std");
const types = @import("types.zig");
const Hardfork = @import("evm").Hardfork;

const Allocator = std.mem.Allocator;
const TestCase = types.TestCase;

pub const ParsedTestFile = struct {
    test_cases: std.StringHashMap(TestCase),
    parsed_json: std.json.Parsed(std.json.Value),
    allocator: Allocator,

    pub fn deinit(self: *ParsedTestFile) void {
        self.test_cases.deinit();
        self.parsed_json.deinit();
    }
};

/// Parse JSON file into test cases
pub fn parseTestFile(allocator: Allocator, file_path: []const u8) !ParsedTestFile {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const contents = try allocator.alloc(u8, file_size);
    defer allocator.free(contents);
    _ = try file.read(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    errdefer parsed.deinit();

    var test_cases = std.StringHashMap(TestCase).init(allocator);
    errdefer test_cases.deinit();

    const root = parsed.value.object;
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        const test_data = entry.value_ptr.*;

        const test_case = try parseTestCase(test_data);
        try test_cases.put(test_name, test_case);
    }

    return ParsedTestFile{
        .test_cases = test_cases,
        .parsed_json = parsed,
        .allocator = allocator,
    };
}

fn parseTestCase(value: std.json.Value) !TestCase {
    const obj = value.object;

    const env = try parseEnv(obj.get("env") orelse return error.MissingEnv);
    const pre = obj.get("pre") orelse return error.MissingPre;
    const transaction = try parseTransaction(obj.get("transaction") orelse return error.MissingTransaction);
    const post = obj.get("post") orelse return error.MissingPost;
    const config = obj.get("config") orelse return error.MissingConfig;
    const info = obj.get("_info");

    return TestCase{
        .env = env,
        .pre = pre,
        .transaction = transaction,
        .post = post,
        .config = .{
            .chainid = config.object.get("chainid").?.string,
        },
        ._info = info,
    };
}

fn parseEnv(value: std.json.Value) !types.Env {
    const obj = value.object;

    return types.Env{
        .currentCoinbase = obj.get("currentCoinbase").?.string,
        .currentGasLimit = obj.get("currentGasLimit").?.string,
        .currentNumber = obj.get("currentNumber").?.string,
        .currentTimestamp = obj.get("currentTimestamp").?.string,
        .currentDifficulty = if (obj.get("currentDifficulty")) |d| d.string else null,
        .currentRandom = if (obj.get("currentRandom")) |r| r.string else null,
        .currentBaseFee = if (obj.get("currentBaseFee")) |b| b.string else null,
        .currentBlobBaseFee = if (obj.get("currentBlobBaseFee")) |b| b.string else null,
    };
}

fn parseTransaction(value: std.json.Value) !types.Transaction {
    const obj = value.object;

    return types.Transaction{
        .nonce = obj.get("nonce").?.string,
        .gasPrice = if (obj.get("gasPrice")) |gp| gp.string else null,
        .maxFeePerGas = if (obj.get("maxFeePerGas")) |mf| mf.string else null,
        .maxPriorityFeePerGas = if (obj.get("maxPriorityFeePerGas")) |mp| mp.string else null,
        .gasLimit = try parseStringArray(obj.get("gasLimit").?),
        .to = if (obj.get("to")) |t| t.string else null,
        .value = try parseStringArray(obj.get("value").?),
        .data = try parseStringArray(obj.get("data").?),
        .sender = obj.get("sender").?.string,
        .secretKey = obj.get("secretKey").?.string,
    };
}

fn parseStringArray(value: std.json.Value) ![][]const u8 {
    const array = value.array;
    var strings = std.ArrayList([]const u8){};

    for (array.items) |item| {
        try strings.append(std.heap.page_allocator, item.string);
    }
    // Note: We're returning data that references the JSON values directly
    // The JSON parse result must outlive this data
    return try strings.toOwnedSlice(std.heap.page_allocator);
}

/// Get hardfork names from post state
pub fn getHardforks(allocator: Allocator, post: std.json.Value) ![][]const u8 {
    if (post != .object) {
        return error.InvalidPostFormat;
    }

    const post_obj = post.object;
    var hardforks = try std.ArrayList([]const u8).initCapacity(allocator, post_obj.count());
    defer hardforks.deinit(allocator);

    var it = post_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        // Duplicate the key string since it's owned by the JSON Value
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        try hardforks.append(allocator, key_copy);
    }

    return try hardforks.toOwnedSlice(allocator);
}

/// Get post state entries for a specific hardfork
pub fn getPostStateEntries(allocator: Allocator, post: std.json.Value, hardfork: []const u8) ![]types.PostStateEntry {
    const fork_entries = post.object.get(hardfork) orelse return error.HardforkNotFound;
    const array = fork_entries.array;

    var entries = try std.ArrayList(types.PostStateEntry).initCapacity(allocator, array.items.len);
    defer entries.deinit(allocator);

    for (array.items) |item| {
        const obj = item.object;
        try entries.append(allocator, .{
            .hash = obj.get("hash").?.string,
            .logs = obj.get("logs").?.string,
            .txbytes = obj.get("txbytes").?.string,
            .indexes = .{
                .data = @intCast(obj.get("indexes").?.object.get("data").?.integer),
                .gas = @intCast(obj.get("indexes").?.object.get("gas").?.integer),
                .value = @intCast(obj.get("indexes").?.object.get("value").?.integer),
            },
            .state = obj.get("state").?,
        });
    }

    return try entries.toOwnedSlice(allocator);
}

/// Parse hardfork string to enum
pub fn parseHardfork(hardfork_str: []const u8) Hardfork {
    if (std.mem.eql(u8, hardfork_str, "Frontier")) return .FRONTIER;
    if (std.mem.eql(u8, hardfork_str, "Homestead")) return .HOMESTEAD;
    if (std.mem.eql(u8, hardfork_str, "Byzantium")) return .BYZANTIUM;
    if (std.mem.eql(u8, hardfork_str, "Constantinople")) return .CONSTANTINOPLE;
    if (std.mem.eql(u8, hardfork_str, "Istanbul")) return .ISTANBUL;
    if (std.mem.eql(u8, hardfork_str, "Berlin")) return .BERLIN;
    if (std.mem.eql(u8, hardfork_str, "London")) return .LONDON;
    if (std.mem.eql(u8, hardfork_str, "Shanghai")) return .SHANGHAI;
    if (std.mem.eql(u8, hardfork_str, "Cancun")) return .CANCUN;
    if (std.mem.eql(u8, hardfork_str, "Prague")) return .PRAGUE;
    // TODO: Osaka not implemented yet, use CANCUN

    // Default to latest
    return .DEFAULT;
}
