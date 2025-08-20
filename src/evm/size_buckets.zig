//! Stub file for backward compatibility with old bucket system
//! This file provides minimal types to satisfy old imports
//! The new bucket system is in analysis2.zig

const std = @import("std");

// Stub types for backward compatibility
pub const Size0Counts = struct {
    count: u16 = 0,
};

pub const Size2Counts = struct {
    count: u16 = 0,
};

pub const Size8Counts = struct {
    count: u16 = 0,
};

pub const Size16Counts = struct {
    count: u16 = 0,
};

pub const Bucket2 = struct {
    data: [0]u8 = .{},
};

pub const Bucket8 = struct {
    data: [0]u8 = .{},
};

pub const Bucket16 = struct {
    data: [0]u8 = .{},
};

pub const JumpdestArray = struct {
    data: [0]u8,

    pub fn init() JumpdestArray {
        return JumpdestArray{ .data = .{} };
    }
};
