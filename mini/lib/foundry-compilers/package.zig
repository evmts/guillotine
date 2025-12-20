const compiler_module = @import("compiler.zig");

pub const Compilers = struct {
    pub const Compiler = compiler_module.Compiler;
};

pub const CompilerSettings = compiler_module.CompilerSettings;
