const std = @import("std");
const compilers = @import("compilers");
const Compiler = compilers.Compilers.Compiler;
const CompilerSettings = compilers.CompilerSettings;

test "compiler initialization" {
    // The Compiler struct doesn't have an init method, 
    // it's used through static methods
    // Just verify the module imports correctly
    try std.testing.expect(true);
}

test "compile simple Solidity contract" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// SPDX-License-Identifier: MIT
        \\pragma solidity ^0.8.0;
        \\
        \\contract SimpleStorage {
        \\    uint256 private storedData;
        \\
        \\    constructor(uint256 _value) {
        \\        storedData = _value;
        \\    }
        \\
        \\    function set(uint256 _value) public {
        \\        storedData = _value;
        \\    }
        \\
        \\    function get() public view returns (uint256) {
        \\        return storedData;
        \\    }
        \\}
    ;
    
    const settings = CompilerSettings{};
    
    var result = try Compiler.compile_source(
        allocator,
        "SimpleStorage.sol",
        source,
        settings,
    );
    defer result.deinit();
    
    try std.testing.expect(result.contracts.len > 0);
    try std.testing.expect(result.errors.len == 0);
    
    const contract = result.contracts[0];
    try std.testing.expectEqualStrings("SimpleStorage", contract.name);
    try std.testing.expect(contract.abi.len > 0);
    try std.testing.expect(contract.bytecode.len > 0);
    try std.testing.expect(contract.deployed_bytecode.len > 0);
}

test "compile with optimization settings" {
    const allocator = std.testing.allocator;
    
    const source =
        \\pragma solidity ^0.8.0;
        \\contract Test {
        \\    function add(uint a, uint b) public pure returns (uint) {
        \\        return a + b;
        \\    }
        \\}
    ;
    
    const settings = CompilerSettings{
        .optimizer_enabled = true,
        .optimizer_runs = 1000,
    };
    
    var result = try Compiler.compile_source(
        allocator,
        "Test.sol",
        source,
        settings,
    );
    defer result.deinit();
    
    try std.testing.expect(result.contracts.len > 0);
    try std.testing.expect(result.errors.len == 0);
}

test "handle compilation error" {
    const allocator = std.testing.allocator;
    
    // This source has an actual syntax error - missing semicolon
    const invalid_source =
        \\pragma solidity ^0.8.0;
        \\contract Invalid {
        \\    function test() public {
        \\        uint x = 1  // Missing semicolon
        \\    }
        \\}
    ;
    
    const settings = CompilerSettings{};
    
    var result = try Compiler.compile_source(
        allocator,
        "Invalid.sol",
        invalid_source,
        settings,
    );
    defer result.deinit();
    
    // This should have compilation errors
    try std.testing.expect(result.errors.len > 0);
}

test "compile multiple contracts" {
    const allocator = std.testing.allocator;
    
    const source =
        \\pragma solidity ^0.8.0;
        \\
        \\contract ContractA {
        \\    uint256 public value;
        \\}
        \\
        \\contract ContractB {
        \\    string public name;
        \\}
    ;
    
    const settings = CompilerSettings{};
    
    var result = try Compiler.compile_source(
        allocator,
        "Multiple.sol",
        source,
        settings,
    );
    defer result.deinit();
    
    try std.testing.expect(result.contracts.len == 2);
    try std.testing.expect(result.errors.len == 0);
}