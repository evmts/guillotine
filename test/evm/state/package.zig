// State tests module

pub const database_interface_test = @import("database_interface_test.zig");
pub const journal_test = @import("journal_test.zig");

test {
    _ = database_interface_test;
    _ = journal_test;
}
