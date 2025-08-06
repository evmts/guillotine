pub const Address = @import("primitives").Address.Address;

pub const BaseMessage = struct {
    sender: Address,
    gas: u64 = 0,
    depth: u11 = 0,
    static: bool = false,
    value: u256 = 0,
};

pub const Message = union(enum) {
    call: struct {
        base: BaseMessage,
        recipient: Address,
        input_data: []const u8 = &[_]u8{},
    },

    delegatecall: struct {
        base: BaseMessage,
        recipient: Address,
        code_address: Address,
        input_data: []const u8 = &[_]u8{},
    },

    callcode: struct {
        base: BaseMessage,
        recipient: Address,
        code_address: Address,
        input_data: []const u8 = &[_]u8{},
    },

    create: struct {
        base: BaseMessage,
        initcode: []const u8,
    },

    create2: struct {
        base: BaseMessage,
        salt: u256,
        initcode: []const u8,
    },
};
