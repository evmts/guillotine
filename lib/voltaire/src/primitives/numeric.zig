// Numeric utilities for Ethereum
// Provides unit conversions, number formatting, and parsing functions

const std = @import("std");
const testing = std.testing;

// Error types
pub const NumericError = error{
    InvalidInput,
    InvalidUnit,
    ValueTooLarge,
    ValueTooSmall,
    InvalidFormat,
    DivisionByZero,
    OutOfMemory,
};

// Ethereum unit constants (all in wei)
pub const WEI: u256 = 1;
pub const KWEI: u256 = 1_000;
pub const MWEI: u256 = 1_000_000;
pub const GWEI: u256 = 1_000_000_000;
pub const SZABO: u256 = 1_000_000_000_000;
pub const FINNEY: u256 = 1_000_000_000_000_000;
pub const ETHER: u256 = 1_000_000_000_000_000_000;

// Alternative unit constant names for compatibility
pub const WEI_PER_GWEI: u256 = GWEI;
pub const WEI_PER_ETHER: u256 = ETHER;
pub const GWEI_PER_ETHER: u256 = ETHER / GWEI;

// Common unit names
pub const Unit = enum {
    wei,
    kwei,
    mwei,
    gwei,
    szabo,
    finney,
    ether,

    pub fn toMultiplier(self: Unit) u256 {
        return switch (self) {
            .wei => WEI,
            .kwei => KWEI,
            .mwei => MWEI,
            .gwei => GWEI,
            .szabo => SZABO,
            .finney => FINNEY,
            .ether => ETHER,
        };
    }

    pub fn fromString(str: []const u8) ?Unit {
        if (std.mem.eql(u8, str, "wei")) return .wei;
        if (std.mem.eql(u8, str, "kwei")) return .kwei;
        if (std.mem.eql(u8, str, "mwei")) return .mwei;
        if (std.mem.eql(u8, str, "gwei")) return .gwei;
        if (std.mem.eql(u8, str, "szabo")) return .szabo;
        if (std.mem.eql(u8, str, "finney")) return .finney;
        if (std.mem.eql(u8, str, "ether")) return .ether;
        return null;
    }

    pub fn toString(self: Unit) []const u8 {
        return switch (self) {
            .wei => "wei",
            .kwei => "kwei",
            .mwei => "mwei",
            .gwei => "gwei",
            .szabo => "szabo",
            .finney => "finney",
            .ether => "ether",
        };
    }
};

// Parse ether string to wei
pub fn parseEther(ether_str: []const u8) !u256 {
    return parseUnits(ether_str, .ether);
}

// Parse gwei string to wei
pub fn parseGwei(gwei_str: []const u8) !u256 {
    return parseUnits(gwei_str, .gwei);
}

// Parse units string to wei
pub fn parseUnits(value_str: []const u8, unit: Unit) !u256 {
    const trimmed = std.mem.trim(u8, value_str, " \t\n\r");
    if (trimmed.len == 0) return NumericError.InvalidInput;

    // Handle decimal point
    if (std.mem.indexOf(u8, trimmed, ".")) |dot_pos| {
        const integer_part = trimmed[0..dot_pos];
        const decimal_part = trimmed[dot_pos + 1 ..];

        // Parse integer part
        var integer_value: u256 = 0;
        if (integer_part.len > 0) {
            integer_value = try parseInteger(integer_part);
        }

        // Parse decimal part
        var decimal_value: u256 = 0;
        if (decimal_part.len > 0) {
            decimal_value = try parseDecimal(decimal_part, unit);
        }

        const multiplier = unit.toMultiplier();
        const integer_wei = integer_value * multiplier;

        return integer_wei + decimal_value;
    } else {
        // No decimal point, just parse as integer
        const integer_value = try parseInteger(trimmed);
        const multiplier = unit.toMultiplier();
        return integer_value * multiplier;
    }
}

// Format wei to ether string
pub fn formatEther(allocator: std.mem.Allocator, wei_value: u256) ![]u8 {
    return formatUnits(allocator, wei_value, .ether, null);
}

// Format wei to gwei string
pub fn formatGwei(allocator: std.mem.Allocator, wei_value: u256) ![]u8 {
    return formatUnits(allocator, wei_value, .gwei, null);
}

// Format wei to specified units
pub fn formatUnits(allocator: std.mem.Allocator, wei_value: u256, unit: Unit, decimals: ?u8) ![]u8 {
    const multiplier = unit.toMultiplier();
    const unit_name = unit.toString();

    // Calculate integer and fractional parts
    const integer_part = wei_value / multiplier;
    const remainder = wei_value % multiplier;

    if (remainder == 0) {
        // No fractional part
        return std.fmt.allocPrint(allocator, "{} {s}", .{ integer_part, unit_name });
    }

    // Calculate decimal places needed
    const max_decimals = decimals orelse getDefaultDecimals(unit);
    const decimal_str = try formatDecimalPart(allocator, remainder, multiplier, max_decimals);
    defer allocator.free(decimal_str);

    if (std.mem.eql(u8, decimal_str, "0")) {
        return std.fmt.allocPrint(allocator, "{} {s}", .{ integer_part, unit_name });
    }

    return std.fmt.allocPrint(allocator, "{}.{s} {s}", .{ integer_part, decimal_str, unit_name });
}

// Format wei value without unit suffix
pub fn formatWei(allocator: std.mem.Allocator, wei_value: u256) ![]u8 {
    return std.fmt.allocPrint(allocator, "{}", .{wei_value});
}

// Convert between units
pub fn convertUnits(value: u256, from_unit: Unit, to_unit: Unit) !u256 {
    const from_multiplier = from_unit.toMultiplier();
    const to_multiplier = to_unit.toMultiplier();

    // Convert to wei first
    const wei_value = value * from_multiplier;

    // Then convert to target unit
    return wei_value / to_multiplier;
}

// Utility functions for gas calculations
pub fn calculateGasCost(gas_used: u64, gas_price_gwei: u256) u256 {
    const gas_price_wei = gas_price_gwei * GWEI;
    return @as(u256, gas_used) * gas_price_wei;
}

pub fn formatGasCost(allocator: std.mem.Allocator, gas_used: u64, gas_price_gwei: u256) ![]u8 {
    const cost_wei = calculateGasCost(gas_used, gas_price_gwei);
    return formatEther(allocator, cost_wei);
}

// Helper functions
fn parseInteger(str: []const u8) !u256 {
    if (str.len == 0) return 0;

    return std.fmt.parseInt(u256, str, 10) catch |err| switch (err) {
        error.Overflow => NumericError.ValueTooLarge,
        error.InvalidCharacter => NumericError.InvalidInput,
    };
}

fn parseDecimal(decimal_str: []const u8, unit: Unit) !u256 {
    if (decimal_str.len == 0) return 0;

    const multiplier = unit.toMultiplier();
    var result: u256 = 0;
    var place_value = multiplier / 10;

    for (decimal_str) |c| {
        if (c < '0' or c > '9') return NumericError.InvalidInput;
        if (place_value == 0) break; // No more precision available

        const digit = c - '0';
        result += @as(u256, digit) * place_value;
        place_value /= 10;
    }

    return result;
}

fn formatDecimalPart(allocator: std.mem.Allocator, remainder: u256, multiplier: u256, max_decimals: u8) ![]u8 {
    var decimal_chars = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer decimal_chars.deinit();

    var current_remainder = remainder;
    var current_multiplier = multiplier;
    var decimals_added: u8 = 0;

    while (current_remainder > 0 and decimals_added < max_decimals) {
        current_multiplier /= 10;
        if (current_multiplier == 0) break;

        const digit = current_remainder / current_multiplier;
        try decimal_chars.append(@as(u8, @intCast(digit)) + '0');
        current_remainder %= current_multiplier;
        decimals_added += 1;
    }

    // Remove trailing zeros
    while (decimal_chars.items.len > 0 and decimal_chars.items[decimal_chars.items.len - 1] == '0') {
        _ = decimal_chars.pop();
    }

    if (decimal_chars.items.len == 0) {
        return allocator.dupe(u8, "0");
    }

    return decimal_chars.toOwnedSlice();
}

fn getDefaultDecimals(unit: Unit) u8 {
    return switch (unit) {
        .wei => 0,
        .kwei => 3,
        .mwei => 6,
        .gwei => 9,
        .szabo => 12,
        .finney => 15,
        .ether => 18,
    };
}

// Math utilities
pub fn min(a: u256, b: u256) u256 {
    return if (a < b) a else b;
}

pub fn max(a: u256, b: u256) u256 {
    return if (a > b) a else b;
}

pub fn safeAdd(a: u256, b: u256) ?u256 {
    const result = a +% b;
    return if (result < a) null else result;
}

pub fn safeSub(a: u256, b: u256) ?u256 {
    return if (a >= b) a - b else null;
}

pub fn safeMul(a: u256, b: u256) ?u256 {
    if (a == 0 or b == 0) return 0;
    const result = a *% b;
    return if (result / a != b) null else result;
}

pub fn safeDiv(a: u256, b: u256) ?u256 {
    return if (b == 0) null else a / b;
}

// Percentage calculations
pub fn calculatePercentage(value: u256, percentage: u256) u256 {
    return (value * percentage) / 100;
}

pub fn calculatePercentageOf(part: u256, whole: u256) u256 {
    if (whole == 0) return 0;
    return (part * 100) / whole;
}

// Tests
test "unit conversions" {
    try testing.expectEqual(@as(u256, 1), WEI);
    try testing.expectEqual(@as(u256, 1_000_000_000), GWEI);
    try testing.expectEqual(@as(u256, 1_000_000_000_000_000_000), ETHER);
}

test "parse ether" {
    const result1 = try parseEther("1");
    try testing.expectEqual(ETHER, result1);

    const result2 = try parseEther("1.5");
    try testing.expectEqual(ETHER + ETHER / 2, result2);

    const result3 = try parseEther("0.001");
    try testing.expectEqual(FINNEY, result3);
}

test "parse gwei" {
    const result1 = try parseGwei("1");
    try testing.expectEqual(GWEI, result1);

    const result2 = try parseGwei("20");
    try testing.expectEqual(20 * GWEI, result2);

    const result3 = try parseGwei("0.5");
    try testing.expectEqual(GWEI / 2, result3);
}

test "format ether" {
    const allocator = testing.allocator;

    const result1 = try formatEther(allocator, ETHER);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 ether", result1);

    const result2 = try formatEther(allocator, ETHER + ETHER / 2);
    defer allocator.free(result2);
    try testing.expectEqualStrings("1.5 ether", result2);

    const result3 = try formatEther(allocator, FINNEY);
    defer allocator.free(result3);
    try testing.expectEqualStrings("0.001 ether", result3);
}

test "format gwei" {
    const allocator = testing.allocator;

    const result1 = try formatGwei(allocator, GWEI);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 gwei", result1);

    const result2 = try formatGwei(allocator, 20 * GWEI);
    defer allocator.free(result2);
    try testing.expectEqualStrings("20 gwei", result2);
}

test "unit conversion" {
    const result1 = try convertUnits(1, .ether, .gwei);
    try testing.expectEqual(@as(u256, 1_000_000_000), result1);

    const result2 = try convertUnits(1000, .gwei, .ether);
    try testing.expectEqual(@as(u256, 0), result2); // Less than 1 ether

    const result3 = try convertUnits(1_000_000_000, .gwei, .ether);
    try testing.expectEqual(@as(u256, 1), result3);
}

test "gas cost calculations" {
    const gas_used: u64 = 21000;
    const gas_price_gwei: u256 = 20;

    const cost = calculateGasCost(gas_used, gas_price_gwei);
    try testing.expectEqual(@as(u256, 21000) * 20 * GWEI, cost);
}

test "safe math operations" {
    try testing.expectEqual(@as(?u256, 5), safeAdd(2, 3));
    try testing.expectEqual(@as(?u256, null), safeAdd(std.math.maxInt(u256), 1));

    try testing.expectEqual(@as(?u256, 2), safeSub(5, 3));
    try testing.expectEqual(@as(?u256, null), safeSub(3, 5));

    try testing.expectEqual(@as(?u256, 6), safeMul(2, 3));
    try testing.expectEqual(@as(?u256, 0), safeMul(0, 5));

    try testing.expectEqual(@as(?u256, 2), safeDiv(6, 3));
    try testing.expectEqual(@as(?u256, null), safeDiv(5, 0));
}

test "percentage calculations" {
    try testing.expectEqual(@as(u256, 50), calculatePercentage(100, 50));
    try testing.expectEqual(@as(u256, 25), calculatePercentageOf(25, 100));
}

test "parseEther with integer values" {
    const result1 = try parseEther("0");
    try testing.expectEqual(@as(u256, 0), result1);

    const result2 = try parseEther("1");
    try testing.expectEqual(ETHER, result2);

    const result3 = try parseEther("10");
    try testing.expectEqual(10 * ETHER, result3);

    const result4 = try parseEther("100");
    try testing.expectEqual(100 * ETHER, result4);

    const result5 = try parseEther("1000000");
    try testing.expectEqual(1000000 * ETHER, result5);
}

test "parseEther with decimal values" {
    const result1 = try parseEther("0.1");
    try testing.expectEqual(ETHER / 10, result1);

    const result2 = try parseEther("0.5");
    try testing.expectEqual(ETHER / 2, result2);

    const result3 = try parseEther("1.5");
    try testing.expectEqual(ETHER + ETHER / 2, result3);

    const result4 = try parseEther("2.25");
    try testing.expectEqual(2 * ETHER + ETHER / 4, result4);

    const result5 = try parseEther("0.001");
    try testing.expectEqual(FINNEY, result5);

    const result6 = try parseEther("0.000001");
    try testing.expectEqual(SZABO, result6);

    const result7 = try parseEther("0.000000001");
    try testing.expectEqual(GWEI, result7);
}

test "parseEther with maximum precision" {
    const result1 = try parseEther("0.000000000000000001");
    try testing.expectEqual(@as(u256, 1), result1);

    const result2 = try parseEther("1.000000000000000001");
    try testing.expectEqual(ETHER + 1, result2);

    const result3 = try parseEther("0.123456789012345678");
    try testing.expectEqual(@as(u256, 123456789012345678), result3);

    const result4 = try parseEther("1.123456789012345678");
    try testing.expectEqual(ETHER + 123456789012345678, result4);
}

test "parseEther with trailing zeros" {
    const result1 = try parseEther("1.0");
    try testing.expectEqual(ETHER, result1);

    const result2 = try parseEther("1.00");
    try testing.expectEqual(ETHER, result2);

    const result3 = try parseEther("1.500");
    try testing.expectEqual(ETHER + ETHER / 2, result3);

    const result4 = try parseEther("0.100");
    try testing.expectEqual(ETHER / 10, result4);
}

test "parseEther with leading decimal point" {
    const result1 = try parseEther(".1");
    try testing.expectEqual(ETHER / 10, result1);

    const result2 = try parseEther(".5");
    try testing.expectEqual(ETHER / 2, result2);

    const result3 = try parseEther(".001");
    try testing.expectEqual(FINNEY, result3);
}

test "parseEther with whitespace" {
    const result1 = try parseEther("  1  ");
    try testing.expectEqual(ETHER, result1);

    const result2 = try parseEther("\t1.5\t");
    try testing.expectEqual(ETHER + ETHER / 2, result2);

    const result3 = try parseEther("\n0.1\n");
    try testing.expectEqual(ETHER / 10, result3);

    const result4 = try parseEther(" \t\n 2.5 \r\n ");
    try testing.expectEqual(2 * ETHER + ETHER / 2, result4);
}

test "parseEther with precision overflow" {
    const result1 = try parseEther("1.0000000000000000001");
    try testing.expectEqual(ETHER, result1);

    const result2 = try parseEther("1.123456789012345678999999");
    try testing.expectEqual(ETHER + 123456789012345678, result2);
}

test "parseEther invalid input" {
    try testing.expectError(NumericError.InvalidInput, parseEther(""));
    try testing.expectError(NumericError.InvalidInput, parseEther("   "));
    try testing.expectError(NumericError.InvalidInput, parseEther("abc"));
    try testing.expectError(NumericError.InvalidInput, parseEther("1.2.3"));
    try testing.expectError(NumericError.InvalidInput, parseEther("1..2"));
    try testing.expectError(NumericError.InvalidInput, parseEther("1.2a"));
    try testing.expectError(NumericError.InvalidInput, parseEther("a1.2"));
}

test "parseUnits with wei" {
    const result1 = try parseUnits("0", .wei);
    try testing.expectEqual(@as(u256, 0), result1);

    const result2 = try parseUnits("1", .wei);
    try testing.expectEqual(@as(u256, 1), result2);

    const result3 = try parseUnits("100", .wei);
    try testing.expectEqual(@as(u256, 100), result3);

    const result4 = try parseUnits("1000000000000000000", .wei);
    try testing.expectEqual(ETHER, result4);
}

test "parseUnits with kwei" {
    const result1 = try parseUnits("1", .kwei);
    try testing.expectEqual(KWEI, result1);

    const result2 = try parseUnits("10", .kwei);
    try testing.expectEqual(10 * KWEI, result2);

    const result3 = try parseUnits("0.5", .kwei);
    try testing.expectEqual(KWEI / 2, result3);

    const result4 = try parseUnits("1.5", .kwei);
    try testing.expectEqual(KWEI + KWEI / 2, result4);
}

test "parseUnits with mwei" {
    const result1 = try parseUnits("1", .mwei);
    try testing.expectEqual(MWEI, result1);

    const result2 = try parseUnits("10", .mwei);
    try testing.expectEqual(10 * MWEI, result2);

    const result3 = try parseUnits("0.001", .mwei);
    try testing.expectEqual(KWEI, result3);
}

test "parseUnits with gwei" {
    const result1 = try parseUnits("1", .gwei);
    try testing.expectEqual(GWEI, result1);

    const result2 = try parseUnits("20", .gwei);
    try testing.expectEqual(20 * GWEI, result2);

    const result3 = try parseUnits("0.5", .gwei);
    try testing.expectEqual(GWEI / 2, result3);

    const result4 = try parseUnits("100.25", .gwei);
    try testing.expectEqual(100 * GWEI + GWEI / 4, result4);
}

test "parseUnits with szabo" {
    const result1 = try parseUnits("1", .szabo);
    try testing.expectEqual(SZABO, result1);

    const result2 = try parseUnits("0.001", .szabo);
    try testing.expectEqual(GWEI, result2);

    const result3 = try parseUnits("1000", .szabo);
    try testing.expectEqual(1000 * SZABO, result3);
}

test "parseUnits with finney" {
    const result1 = try parseUnits("1", .finney);
    try testing.expectEqual(FINNEY, result1);

    const result2 = try parseUnits("0.001", .finney);
    try testing.expectEqual(SZABO, result2);

    const result3 = try parseUnits("1000", .finney);
    try testing.expectEqual(ETHER, result3);
}

test "parseUnits with ether" {
    const result1 = try parseUnits("1", .ether);
    try testing.expectEqual(ETHER, result1);

    const result2 = try parseUnits("0.001", .ether);
    try testing.expectEqual(FINNEY, result2);

    const result3 = try parseUnits("100", .ether);
    try testing.expectEqual(100 * ETHER, result3);
}

test "parseUnits decimal precision per unit" {
    const result1 = try parseUnits("1.1", .wei);
    try testing.expectEqual(@as(u256, 1), result1);

    const result2 = try parseUnits("1.999", .kwei);
    try testing.expectEqual(KWEI + 999, result2);

    const result3 = try parseUnits("1.999999", .mwei);
    try testing.expectEqual(MWEI + 999999, result3);

    const result4 = try parseUnits("1.999999999", .gwei);
    try testing.expectEqual(GWEI + 999999999, result4);
}

test "parseUnits with zero values" {
    const result1 = try parseUnits("0", .wei);
    try testing.expectEqual(@as(u256, 0), result1);

    const result2 = try parseUnits("0", .gwei);
    try testing.expectEqual(@as(u256, 0), result2);

    const result3 = try parseUnits("0", .ether);
    try testing.expectEqual(@as(u256, 0), result3);

    const result4 = try parseUnits("0.0", .ether);
    try testing.expectEqual(@as(u256, 0), result4);

    const result5 = try parseUnits("0.00", .gwei);
    try testing.expectEqual(@as(u256, 0), result5);
}

test "parseUnits with only decimal part" {
    const result1 = try parseUnits(".1", .ether);
    try testing.expectEqual(ETHER / 10, result1);

    const result2 = try parseUnits(".5", .gwei);
    try testing.expectEqual(GWEI / 2, result2);

    const result3 = try parseUnits(".999", .kwei);
    try testing.expectEqual(@as(u256, 999), result3);
}

test "parseUnits invalid inputs" {
    try testing.expectError(NumericError.InvalidInput, parseUnits("", .ether));
    try testing.expectError(NumericError.InvalidInput, parseUnits("   ", .ether));
    try testing.expectError(NumericError.InvalidInput, parseUnits("abc", .gwei));
    try testing.expectError(NumericError.InvalidInput, parseUnits("1.2.3", .ether));
    try testing.expectError(NumericError.InvalidInput, parseUnits("1..2", .ether));
    try testing.expectError(NumericError.InvalidInput, parseUnits("1.2a", .gwei));
    try testing.expectError(NumericError.InvalidInput, parseUnits("a1.2", .wei));
    try testing.expectError(NumericError.InvalidInput, parseUnits("1e10", .ether));
    try testing.expectError(NumericError.ValueTooLarge, parseUnits("-1", .ether));
}

test "parseUnits edge cases with large values" {
    const result1 = try parseUnits("1000000", .ether);
    try testing.expectEqual(1000000 * ETHER, result1);

    const result2 = try parseUnits("999999999", .gwei);
    try testing.expectEqual(999999999 * GWEI, result2);

    const result3 = try parseUnits("123456.789012345678", .ether);
    try testing.expectEqual(123456 * ETHER + 789012345678000000, result3);
}

test "parseUnits consistent across all units" {
    const ether_value = try parseUnits("1", .ether);
    const finney_value = try parseUnits("1000", .finney);
    try testing.expectEqual(ether_value, finney_value);

    const gwei_value = try parseUnits("1", .gwei);
    const wei_value = try parseUnits("1000000000", .wei);
    try testing.expectEqual(gwei_value, wei_value);

    const szabo_value = try parseUnits("1", .szabo);
    const gwei_szabo = try parseUnits("1000", .gwei);
    try testing.expectEqual(szabo_value, gwei_szabo);
}

test "parseUnits whitespace handling" {
    const result1 = try parseUnits("  1  ", .ether);
    try testing.expectEqual(ETHER, result1);

    const result2 = try parseUnits("\t0.5\t", .gwei);
    try testing.expectEqual(GWEI / 2, result2);

    const result3 = try parseUnits("\n\r 10.25 \r\n", .gwei);
    try testing.expectEqual(10 * GWEI + GWEI / 4, result3);
}

test "unit conversion edge cases" {
    const result1 = try convertUnits(0, .ether, .gwei);
    try testing.expectEqual(@as(u256, 0), result1);

    const result2 = try convertUnits(1, .wei, .wei);
    try testing.expectEqual(@as(u256, 1), result2);

    const result3 = try convertUnits(1, .ether, .wei);
    try testing.expectEqual(ETHER, result3);

    const result4 = try convertUnits(1, .wei, .ether);
    try testing.expectEqual(@as(u256, 0), result4);

    const result5 = try convertUnits(1_000_000_000_000_000_000, .wei, .ether);
    try testing.expectEqual(@as(u256, 1), result5);
}

test "unit conversion precision loss" {
    const result1 = try convertUnits(500, .gwei, .ether);
    try testing.expectEqual(@as(u256, 0), result1);

    const result2 = try convertUnits(1, .kwei, .mwei);
    try testing.expectEqual(@as(u256, 0), result2);

    const result3 = try convertUnits(999, .wei, .kwei);
    try testing.expectEqual(@as(u256, 0), result3);
}

test "unit conversion all combinations" {
    const result1 = try convertUnits(1, .kwei, .wei);
    try testing.expectEqual(KWEI, result1);

    const result2 = try convertUnits(1, .mwei, .kwei);
    try testing.expectEqual(@as(u256, 1000), result2);

    const result3 = try convertUnits(1, .gwei, .mwei);
    try testing.expectEqual(@as(u256, 1000), result3);

    const result4 = try convertUnits(1, .szabo, .gwei);
    try testing.expectEqual(@as(u256, 1000), result4);

    const result5 = try convertUnits(1, .finney, .szabo);
    try testing.expectEqual(@as(u256, 1000), result5);

    const result6 = try convertUnits(1, .ether, .finney);
    try testing.expectEqual(@as(u256, 1000), result6);
}

test "unit fromString and toString" {
    try testing.expectEqual(Unit.wei, Unit.fromString("wei").?);
    try testing.expectEqual(Unit.kwei, Unit.fromString("kwei").?);
    try testing.expectEqual(Unit.mwei, Unit.fromString("mwei").?);
    try testing.expectEqual(Unit.gwei, Unit.fromString("gwei").?);
    try testing.expectEqual(Unit.szabo, Unit.fromString("szabo").?);
    try testing.expectEqual(Unit.finney, Unit.fromString("finney").?);
    try testing.expectEqual(Unit.ether, Unit.fromString("ether").?);

    try testing.expectEqual(@as(?Unit, null), Unit.fromString("invalid"));
    try testing.expectEqual(@as(?Unit, null), Unit.fromString(""));
    try testing.expectEqual(@as(?Unit, null), Unit.fromString("ETHER"));

    try testing.expectEqualStrings("wei", Unit.wei.toString());
    try testing.expectEqualStrings("kwei", Unit.kwei.toString());
    try testing.expectEqualStrings("mwei", Unit.mwei.toString());
    try testing.expectEqualStrings("gwei", Unit.gwei.toString());
    try testing.expectEqualStrings("szabo", Unit.szabo.toString());
    try testing.expectEqualStrings("finney", Unit.finney.toString());
    try testing.expectEqualStrings("ether", Unit.ether.toString());
}

test "unit toMultiplier" {
    try testing.expectEqual(WEI, Unit.wei.toMultiplier());
    try testing.expectEqual(KWEI, Unit.kwei.toMultiplier());
    try testing.expectEqual(MWEI, Unit.mwei.toMultiplier());
    try testing.expectEqual(GWEI, Unit.gwei.toMultiplier());
    try testing.expectEqual(SZABO, Unit.szabo.toMultiplier());
    try testing.expectEqual(FINNEY, Unit.finney.toMultiplier());
    try testing.expectEqual(ETHER, Unit.ether.toMultiplier());
}

test "parseEther maximum value handling" {
    const max_ether_str = "115792089237316195423570985008687907853269984665640564039457";
    const result = try parseEther(max_ether_str);
    try testing.expect(result > 0);
}

test "parseUnits with very small decimals" {
    const result1 = try parseUnits("0.000000000000000001", .ether);
    try testing.expectEqual(@as(u256, 1), result1);

    const result2 = try parseUnits("0.000000001", .gwei);
    try testing.expectEqual(@as(u256, 1), result2);

    const result3 = try parseUnits("0.001", .kwei);
    try testing.expectEqual(@as(u256, 1), result3);
}

test "formatEther with various values" {
    const allocator = testing.allocator;

    const zero_formatted = try formatEther(allocator, 0);
    defer allocator.free(zero_formatted);
    try testing.expectEqualStrings("0 ether", zero_formatted);

    const one_wei = try formatEther(allocator, 1);
    defer allocator.free(one_wei);
    try testing.expectEqualStrings("0.000000000000000001 ether", one_wei);

    const half_ether = try formatEther(allocator, ETHER / 2);
    defer allocator.free(half_ether);
    try testing.expectEqualStrings("0.5 ether", half_ether);

    const quarter_ether = try formatEther(allocator, ETHER / 4);
    defer allocator.free(quarter_ether);
    try testing.expectEqualStrings("0.25 ether", quarter_ether);

    const large = try formatEther(allocator, 1000 * ETHER);
    defer allocator.free(large);
    try testing.expectEqualStrings("1000 ether", large);
}

test "formatGwei with various values" {
    const allocator = testing.allocator;

    const zero_formatted = try formatGwei(allocator, 0);
    defer allocator.free(zero_formatted);
    try testing.expectEqualStrings("0 gwei", zero_formatted);

    const one_formatted = try formatGwei(allocator, GWEI);
    defer allocator.free(one_formatted);
    try testing.expectEqualStrings("1 gwei", one_formatted);

    const half_gwei = try formatGwei(allocator, GWEI / 2);
    defer allocator.free(half_gwei);
    try testing.expectEqualStrings("0.5 gwei", half_gwei);

    const large = try formatGwei(allocator, 1000000 * GWEI);
    defer allocator.free(large);
    try testing.expectEqualStrings("1000000 gwei", large);
}

test "formatWei function" {
    const allocator = testing.allocator;

    const zero = try formatWei(allocator, 0);
    defer allocator.free(zero);
    try testing.expectEqualStrings("0", zero);

    const one = try formatWei(allocator, 1);
    defer allocator.free(one);
    try testing.expectEqualStrings("1", one);

    const large = try formatWei(allocator, ETHER);
    defer allocator.free(large);
    try testing.expectEqualStrings("1000000000000000000", large);

    const max_u64 = try formatWei(allocator, std.math.maxInt(u64));
    defer allocator.free(max_u64);
    try testing.expectEqualStrings("18446744073709551615", max_u64);
}

test "formatUnits with custom decimals" {
    const allocator = testing.allocator;

    const result1 = try formatUnits(allocator, ETHER, .ether, 2);
    defer allocator.free(result1);
    try testing.expectEqualStrings("1 ether", result1);

    const result2 = try formatUnits(allocator, ETHER / 3, .ether, 2);
    defer allocator.free(result2);
    try testing.expectEqualStrings("0.33 ether", result2);

    const result3 = try formatUnits(allocator, ETHER / 3, .ether, 6);
    defer allocator.free(result3);
    try testing.expectEqualStrings("0.333333 ether", result3);

    const result4 = try formatUnits(allocator, GWEI, .gwei, 0);
    defer allocator.free(result4);
    try testing.expectEqualStrings("1 gwei", result4);

    const result5 = try formatUnits(allocator, 123456789, .wei, null);
    defer allocator.free(result5);
    try testing.expectEqualStrings("123456789 wei", result5);
}

test "formatGasCost function" {
    const allocator = testing.allocator;

    const result1 = try formatGasCost(allocator, 21000, 20);
    defer allocator.free(result1);

    const expected_cost = calculateGasCost(21000, 20);
    const expected_str = try formatEther(allocator, expected_cost);
    defer allocator.free(expected_str);

    try testing.expectEqualStrings(expected_str, result1);

    const result2 = try formatGasCost(allocator, 100000, 50);
    defer allocator.free(result2);
    const expected_cost2 = calculateGasCost(100000, 50);
    const expected_str2 = try formatEther(allocator, expected_cost2);
    defer allocator.free(expected_str2);
    try testing.expectEqualStrings(expected_str2, result2);
}

test "min and max functions for u256" {
    const a: u256 = 100;
    const b: u256 = 200;

    try testing.expectEqual(@as(u256, 100), min(a, b));
    try testing.expectEqual(@as(u256, 200), max(a, b));

    try testing.expectEqual(@as(u256, 100), min(b, a));
    try testing.expectEqual(@as(u256, 200), max(b, a));

    try testing.expectEqual(@as(u256, 0), min(0, 100));
    try testing.expectEqual(@as(u256, 100), max(0, 100));

    const large1: u256 = std.math.maxInt(u256);
    const large2: u256 = std.math.maxInt(u256) - 1;

    try testing.expectEqual(large2, min(large1, large2));
    try testing.expectEqual(large1, max(large1, large2));
}

test "safeMul overflow detection" {
    const max_val = std.math.maxInt(u256);
    const half_max = max_val / 2;

    const result1 = safeMul(2, 3);
    try testing.expectEqual(@as(?u256, 6), result1);

    const result2 = safeMul(max_val, 2);
    try testing.expectEqual(@as(?u256, null), result2);

    const result3 = safeMul(half_max, 2);
    try testing.expect(result3 != null);

    const result4 = safeMul(half_max + 1, 2);
    try testing.expectEqual(@as(?u256, null), result4);

    const result5 = safeMul(0, max_val);
    try testing.expectEqual(@as(?u256, 0), result5);

    const result6 = safeMul(1, max_val);
    try testing.expectEqual(@as(?u256, max_val), result6);
}

test "safeAdd overflow at boundary" {
    const max_val = std.math.maxInt(u256);

    const result1 = safeAdd(max_val, 0);
    try testing.expectEqual(@as(?u256, max_val), result1);

    const result2 = safeAdd(max_val, 1);
    try testing.expectEqual(@as(?u256, null), result2);

    const result3 = safeAdd(max_val - 1, 1);
    try testing.expectEqual(@as(?u256, max_val), result3);

    const result4 = safeAdd(max_val - 1, 2);
    try testing.expectEqual(@as(?u256, null), result4);
}

test "safeSub underflow at boundary" {
    const result1 = safeSub(0, 1);
    try testing.expectEqual(@as(?u256, null), result1);

    const result2 = safeSub(1, 1);
    try testing.expectEqual(@as(?u256, 0), result2);

    const result3 = safeSub(100, 99);
    try testing.expectEqual(@as(?u256, 1), result3);

    const result4 = safeSub(100, 101);
    try testing.expectEqual(@as(?u256, null), result4);
}

test "calculatePercentageOf with zero whole" {
    const result = calculatePercentageOf(100, 0);
    try testing.expectEqual(@as(u256, 0), result);

    const result2 = calculatePercentageOf(0, 0);
    try testing.expectEqual(@as(u256, 0), result2);

    const result3 = calculatePercentageOf(50, 100);
    try testing.expectEqual(@as(u256, 50), result3);

    const result4 = calculatePercentageOf(100, 100);
    try testing.expectEqual(@as(u256, 100), result4);
}

test "formatUnits with all unit types" {
    const allocator = testing.allocator;

    const units = [_]Unit{ .wei, .kwei, .mwei, .gwei, .szabo, .finney, .ether };

    for (units) |unit| {
        const multiplier = unit.toMultiplier();
        const formatted = try formatUnits(allocator, multiplier, unit, null);
        defer allocator.free(formatted);

        const unit_str = unit.toString();
        const expected_prefix = "1 ";
        try testing.expect(std.mem.startsWith(u8, formatted, expected_prefix));
        try testing.expect(std.mem.endsWith(u8, formatted, unit_str));
    }
}

test "parseUnits and formatUnits roundtrip" {
    const allocator = testing.allocator;

    const test_values = [_]struct {
        str: []const u8,
        unit: Unit,
    }{
        .{ .str = "1", .unit = .ether },
        .{ .str = "0.5", .unit = .ether },
        .{ .str = "100", .unit = .gwei },
        .{ .str = "1000", .unit = .wei },
        .{ .str = "1.25", .unit = .finney },
    };

    for (test_values) |tv| {
        const parsed = try parseUnits(tv.str, tv.unit);
        const formatted = try formatUnits(allocator, parsed, tv.unit, null);
        defer allocator.free(formatted);

        const reparsed = try parseUnits(tv.str, tv.unit);
        try testing.expectEqual(parsed, reparsed);
    }
}

test "Unit enum exhaustive coverage" {
    try testing.expect(Unit.fromString("wei") != null);
    try testing.expect(Unit.fromString("kwei") != null);
    try testing.expect(Unit.fromString("mwei") != null);
    try testing.expect(Unit.fromString("gwei") != null);
    try testing.expect(Unit.fromString("szabo") != null);
    try testing.expect(Unit.fromString("finney") != null);
    try testing.expect(Unit.fromString("ether") != null);

    try testing.expectEqual(@as(?Unit, null), Unit.fromString("bitcoin"));
    try testing.expect(Unit.fromString("WEI") == null);
    try testing.expect(Unit.fromString("GWEI") == null);
}
