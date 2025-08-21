const std = @import("std");

// Import main modules
pub const FrameConfig = @import("frame.zig").FrameConfig;
pub const createColdFrame = @import("frame.zig").createColdFrame;
pub const Analysis = @import("analysis.zig").Analysis;
pub const Interpreter = @import("interpreter.zig").Interpreter;
pub const Dispatcher = @import("dispatcher.zig").Dispatcher;
pub const Evm = @import("evm.zig").Evm;
pub const Tracer = @import("tracer.zig").Tracer;
pub const DetailedStructLog = @import("tracer.zig").DetailedStructLog;
pub const TracerConfig = @import("tracer.zig").TracerConfig;
pub const MemoryCaptureMode = @import("tracer.zig").MemoryCaptureMode;
pub const LoggingTracer = @import("tracer.zig").LoggingTracer;
pub const FileTracer = @import("tracer.zig").FileTracer;
pub const NoOpTracer = @import("noop_tracer.zig").NoOpTracer;

// Export opcode data
pub const opcode_data = @import("opcode_data.zig");

// Opcode namespace
pub const opcodes = struct {
    pub const Opcode = @import("opcodes/opcode.zig").Opcode;
    
    // Regular opcodes
    pub const Op00 = @import("opcodes/00-stop.zig").Op00;
    pub const Op01 = @import("opcodes/01-add.zig").Op01;
    pub const Op02 = @import("opcodes/02-mul.zig").Op02;
    pub const Op03 = @import("opcodes/03-sub.zig").Op03;
    pub const Op04 = @import("opcodes/04-div.zig").Op04;
    pub const Op05 = @import("opcodes/05-sdiv.zig").Op05;
    pub const Op06 = @import("opcodes/06-mod.zig").Op06;
    pub const Op07 = @import("opcodes/07-smod.zig").Op07;
    pub const Op08 = @import("opcodes/08-addmod.zig").Op08;
    pub const Op09 = @import("opcodes/09-mulmod.zig").Op09;
    pub const Op0A = @import("opcodes/0a-exp.zig").Op0A;
    pub const Op0B = @import("opcodes/0b-signextend.zig").Op0B;
    pub const Op10 = @import("opcodes/10-lt.zig").Op10;
    pub const Op11 = @import("opcodes/11-gt.zig").Op11;
    pub const Op12 = @import("opcodes/12-slt.zig").Op12;
    pub const Op13 = @import("opcodes/13-sgt.zig").Op13;
    pub const Op14 = @import("opcodes/14-eq.zig").Op14;
    pub const Op15 = @import("opcodes/15-iszero.zig").Op15;
    pub const Op16 = @import("opcodes/16-and.zig").Op16;
    pub const Op17 = @import("opcodes/17-or.zig").Op17;
    pub const Op18 = @import("opcodes/18-xor.zig").Op18;
    pub const Op19 = @import("opcodes/19-not.zig").Op19;
    pub const Op1A = @import("opcodes/1a-byte.zig").Op1A;
    pub const Op1B = @import("opcodes/1b-shl.zig").Op1B;
    pub const Op1C = @import("opcodes/1c-shr.zig").Op1C;
    pub const Op1D = @import("opcodes/1d-sar.zig").Op1D;
    pub const Op20 = @import("opcodes/20-keccak256.zig").Op20;
    pub const Op30 = @import("opcodes/30-address.zig").Op30;
    pub const Op31 = @import("opcodes/31-balance.zig").Op31;
    pub const Op32 = @import("opcodes/32-origin.zig").Op32;
    pub const Op33 = @import("opcodes/33-caller.zig").Op33;
    pub const Op34 = @import("opcodes/34-callvalue.zig").Op34;
    pub const Op35 = @import("opcodes/35-calldataload.zig").Op35;
    pub const Op36 = @import("opcodes/36-calldatasize.zig").Op36;
    pub const Op37 = @import("opcodes/37-calldatacopy.zig").Op37;
    pub const Op38 = @import("opcodes/38-codesize.zig").Op38;
    pub const Op39 = @import("opcodes/39-codecopy.zig").Op39;
    pub const Op3A = @import("opcodes/3a-gasprice.zig").Op3A;
    pub const Op3B = @import("opcodes/3b-extcodesize.zig").Op3B;
    pub const Op3C = @import("opcodes/3c-extcodecopy.zig").Op3C;
    pub const Op3D = @import("opcodes/3d-returndatasize.zig").Op3D;
    pub const Op3E = @import("opcodes/3e-returndatacopy.zig").Op3E;
    pub const Op3F = @import("opcodes/3f-extcodehash.zig").Op3F;
    pub const Op40 = @import("opcodes/40-blockhash.zig").Op40;
    pub const Op41 = @import("opcodes/41-coinbase.zig").Op41;
    pub const Op42 = @import("opcodes/42-timestamp.zig").Op42;
    pub const Op43 = @import("opcodes/43-number.zig").Op43;
    pub const Op44 = @import("opcodes/44-difficulty.zig").Op44;
    pub const Op45 = @import("opcodes/45-gaslimit.zig").Op45;
    pub const Op46 = @import("opcodes/46-chainid.zig").Op46;
    pub const Op47 = @import("opcodes/47-selfbalance.zig").Op47;
    pub const Op48 = @import("opcodes/48-basefee.zig").Op48;
    pub const Op49 = @import("opcodes/49-blobhash.zig").Op49;
    pub const Op4A = @import("opcodes/4a-blobbasefee.zig").Op4A;
    pub const Op50 = @import("opcodes/50-pop.zig").Op50;
    pub const Op51 = @import("opcodes/51-mload.zig").Op51;
    pub const Op52 = @import("opcodes/52-mstore.zig").Op52;
    pub const Op53 = @import("opcodes/53-mstore8.zig").Op53;
    pub const Op54 = @import("opcodes/54-sload.zig").Op54;
    pub const Op55 = @import("opcodes/55-sstore.zig").Op55;
    pub const Op56 = @import("opcodes/56-jump.zig").Op56;
    pub const Op57 = @import("opcodes/57-jumpi.zig").Op57;
    pub const Op58 = @import("opcodes/58-pc.zig").Op58;
    pub const Op59 = @import("opcodes/59-msize.zig").Op59;
    pub const Op5A = @import("opcodes/5a-gas.zig").Op5A;
    pub const Op5B = @import("opcodes/5b-jumpdest.zig").Op5B;
    pub const Op5C = @import("opcodes/5c-tload.zig").Op5C;
    pub const Op5D = @import("opcodes/5d-tstore.zig").Op5D;
    pub const Op5E = @import("opcodes/5e-mcopy.zig").Op5E;
    pub const Op5F = @import("opcodes/5f-push0.zig").Op5F;
    
    // PUSH operations
    pub const Op60 = @import("opcodes/60-push1.zig").Op60;
    pub const Op61 = @import("opcodes/61-push2.zig").Op61;
    pub const Op62 = @import("opcodes/62-push3.zig").Op62;
    pub const Op63 = @import("opcodes/63-push4.zig").Op63;
    pub const Op64 = @import("opcodes/64-push5.zig").Op64;
    pub const Op65 = @import("opcodes/65-push6.zig").Op65;
    pub const Op66 = @import("opcodes/66-push7.zig").Op66;
    pub const Op67 = @import("opcodes/67-push8.zig").Op67;
    pub const Op68 = @import("opcodes/68-push9.zig").Op68;
    pub const Op69 = @import("opcodes/69-push10.zig").Op69;
    pub const Op6A = @import("opcodes/6a-push11.zig").Op6A;
    pub const Op6B = @import("opcodes/6b-push12.zig").Op6B;
    pub const Op6C = @import("opcodes/6c-push13.zig").Op6C;
    pub const Op6D = @import("opcodes/6d-push14.zig").Op6D;
    pub const Op6E = @import("opcodes/6e-push15.zig").Op6E;
    pub const Op6F = @import("opcodes/6f-push16.zig").Op6F;
    pub const Op70 = @import("opcodes/70-push17.zig").Op70;
    pub const Op71 = @import("opcodes/71-push18.zig").Op71;
    pub const Op72 = @import("opcodes/72-push19.zig").Op72;
    pub const Op73 = @import("opcodes/73-push20.zig").Op73;
    pub const Op74 = @import("opcodes/74-push21.zig").Op74;
    pub const Op75 = @import("opcodes/75-push22.zig").Op75;
    pub const Op76 = @import("opcodes/76-push23.zig").Op76;
    pub const Op77 = @import("opcodes/77-push24.zig").Op77;
    pub const Op78 = @import("opcodes/78-push25.zig").Op78;
    pub const Op79 = @import("opcodes/79-push26.zig").Op79;
    pub const Op7A = @import("opcodes/7a-push27.zig").Op7A;
    pub const Op7B = @import("opcodes/7b-push28.zig").Op7B;
    pub const Op7C = @import("opcodes/7c-push29.zig").Op7C;
    pub const Op7D = @import("opcodes/7d-push30.zig").Op7D;
    pub const Op7E = @import("opcodes/7e-push31.zig").Op7E;
    pub const Op7F = @import("opcodes/7f-push32.zig").Op7F;
    
    // DUP operations
    pub const Op80 = @import("opcodes/80-dup1.zig").Op80;
    pub const Op81 = @import("opcodes/81-dup2.zig").Op81;
    pub const Op82 = @import("opcodes/82-dup3.zig").Op82;
    pub const Op83 = @import("opcodes/83-dup4.zig").Op83;
    pub const Op84 = @import("opcodes/84-dup5.zig").Op84;
    pub const Op85 = @import("opcodes/85-dup6.zig").Op85;
    pub const Op86 = @import("opcodes/86-dup7.zig").Op86;
    pub const Op87 = @import("opcodes/87-dup8.zig").Op87;
    pub const Op88 = @import("opcodes/88-dup9.zig").Op88;
    pub const Op89 = @import("opcodes/89-dup10.zig").Op89;
    pub const Op8A = @import("opcodes/8a-dup11.zig").Op8A;
    pub const Op8B = @import("opcodes/8b-dup12.zig").Op8B;
    pub const Op8C = @import("opcodes/8c-dup13.zig").Op8C;
    pub const Op8D = @import("opcodes/8d-dup14.zig").Op8D;
    pub const Op8E = @import("opcodes/8e-dup15.zig").Op8E;
    pub const Op8F = @import("opcodes/8f-dup16.zig").Op8F;
    
    // SWAP operations
    pub const Op90 = @import("opcodes/90-swap1.zig").Op90;
    pub const Op91 = @import("opcodes/91-swap2.zig").Op91;
    pub const Op92 = @import("opcodes/92-swap3.zig").Op92;
    pub const Op93 = @import("opcodes/93-swap4.zig").Op93;
    pub const Op94 = @import("opcodes/94-swap5.zig").Op94;
    pub const Op95 = @import("opcodes/95-swap6.zig").Op95;
    pub const Op96 = @import("opcodes/96-swap7.zig").Op96;
    pub const Op97 = @import("opcodes/97-swap8.zig").Op97;
    pub const Op98 = @import("opcodes/98-swap9.zig").Op98;
    pub const Op99 = @import("opcodes/99-swap10.zig").Op99;
    pub const Op9A = @import("opcodes/9a-swap11.zig").Op9A;
    pub const Op9B = @import("opcodes/9b-swap12.zig").Op9B;
    pub const Op9C = @import("opcodes/9c-swap13.zig").Op9C;
    pub const Op9D = @import("opcodes/9d-swap14.zig").Op9D;
    pub const Op9E = @import("opcodes/9e-swap15.zig").Op9E;
    pub const Op9F = @import("opcodes/9f-swap16.zig").Op9F;
    
    // LOG operations
    pub const OpA0 = @import("opcodes/a0-log0.zig").OpA0;
    pub const OpA1 = @import("opcodes/a1-log1.zig").OpA1;
    pub const OpA2 = @import("opcodes/a2-log2.zig").OpA2;
    pub const OpA3 = @import("opcodes/a3-log3.zig").OpA3;
    pub const OpA4 = @import("opcodes/a4-log4.zig").OpA4;
    
    // System operations
    pub const OpF0 = @import("opcodes/f0-create.zig").OpF0;
    pub const OpF1 = @import("opcodes/f1-call.zig").OpF1;
    pub const OpF2 = @import("opcodes/f2-callcode.zig").OpF2;
    pub const OpF3 = @import("opcodes/f3-return.zig").OpF3;
    pub const OpF4 = @import("opcodes/f4-delegatecall.zig").OpF4;
    pub const OpF5 = @import("opcodes/f5-create2.zig").OpF5;
    pub const OpFA = @import("opcodes/fa-staticcall.zig").OpFA;
    pub const OpFD = @import("opcodes/fd-revert.zig").OpFD;
    pub const OpFE = @import("opcodes/fe-invalid.zig").OpFE;
    pub const OpFF = @import("opcodes/ff-selfdestruct.zig").OpFF;
    
    // Fusion operations
    pub const Op100 = @import("opcodes/100-push_then_jump.zig").Op100;
    pub const Op101 = @import("opcodes/101-push_then_jumpi.zig").Op101;
    pub const Op102 = @import("opcodes/102-push_then_mload.zig").Op102;
    pub const Op103 = @import("opcodes/103-push_then_mstore.zig").Op103;
    pub const Op104 = @import("opcodes/104-push_then_eq.zig").Op104;
    pub const Op105 = @import("opcodes/105-push_then_lt.zig").Op105;
    pub const Op106 = @import("opcodes/106-push_then_gt.zig").Op106;
    pub const Op107 = @import("opcodes/107-push_then_and.zig").Op107;
    pub const Op108 = @import("opcodes/108-push_then_add.zig").Op108;
    pub const Op109 = @import("opcodes/109-push_then_sub.zig").Op109;
    pub const Op10A = @import("opcodes/10a-push_then_mul.zig").Op10A;
    pub const Op10B = @import("opcodes/10b-push_then_div.zig").Op10B;
    pub const Op10C = @import("opcodes/10c-push_then_sload.zig").Op10C;
    pub const Op10D = @import("opcodes/10d-push_then_dup1.zig").Op10D;
    pub const Op10E = @import("opcodes/10e-push_then_swap1.zig").Op10E;
    pub const Op10F = @import("opcodes/10f-push_then_mload_small.zig").Op10F;
    pub const Op110 = @import("opcodes/110-push_then_mstore_small.zig").Op110;
    pub const Op111 = @import("opcodes/111-push_then_eq_small.zig").Op111;
    pub const Op112 = @import("opcodes/112-push_then_lt_small.zig").Op112;
    pub const Op113 = @import("opcodes/113-push_then_gt_small.zig").Op113;
    pub const Op114 = @import("opcodes/114-push_then_and_small.zig").Op114;
    pub const Op115 = @import("opcodes/115-push_then_add_small.zig").Op115;
    pub const Op116 = @import("opcodes/116-push_then_sub_small.zig").Op116;
    pub const Op117 = @import("opcodes/117-push_then_mul_small.zig").Op117;
    pub const Op118 = @import("opcodes/118-push_then_div_small.zig").Op118;
    pub const Op119 = @import("opcodes/119-push_then_sload_small.zig").Op119;
    pub const Op11A = @import("opcodes/11a-push_then_dup1_small.zig").Op11A;
    pub const Op11B = @import("opcodes/11b-push_then_swap1_small.zig").Op11B;
    pub const Op11C = @import("opcodes/11c-push_then_keccak.zig").Op11C;
    pub const Op11D = @import("opcodes/11d-push_then_keccak_small.zig").Op11D;
    pub const Op11E = @import("opcodes/11e-nop.zig").Op11E;
};

// Run all tests
test {
    // Test main modules
    _ = FrameConfig;
    _ = createColdFrame;
    _ = Analysis;
    _ = Interpreter;
    _ = Dispatcher;
    _ = Evm;
    _ = Tracer;
    _ = DetailedStructLog;
    
    // Test opcodes
    _ = opcodes.Opcode;
    
    // Test all regular opcodes
    _ = opcodes.Op00;
    _ = opcodes.Op01;
    _ = opcodes.Op02;
    _ = opcodes.Op03;
    _ = opcodes.Op04;
    _ = opcodes.Op05;
    _ = opcodes.Op06;
    _ = opcodes.Op07;
    _ = opcodes.Op08;
    _ = opcodes.Op09;
    _ = opcodes.Op0A;
    _ = opcodes.Op0B;
    _ = opcodes.Op10;
    _ = opcodes.Op11;
    _ = opcodes.Op12;
    _ = opcodes.Op13;
    _ = opcodes.Op14;
    _ = opcodes.Op15;
    _ = opcodes.Op16;
    _ = opcodes.Op17;
    _ = opcodes.Op18;
    _ = opcodes.Op19;
    _ = opcodes.Op1A;
    _ = opcodes.Op1B;
    _ = opcodes.Op1C;
    _ = opcodes.Op1D;
    _ = opcodes.Op20;
    _ = opcodes.Op30;
    _ = opcodes.Op31;
    _ = opcodes.Op32;
    _ = opcodes.Op33;
    _ = opcodes.Op34;
    _ = opcodes.Op35;
    _ = opcodes.Op36;
    _ = opcodes.Op37;
    _ = opcodes.Op38;
    _ = opcodes.Op39;
    _ = opcodes.Op3A;
    _ = opcodes.Op3B;
    _ = opcodes.Op3C;
    _ = opcodes.Op3D;
    _ = opcodes.Op3E;
    _ = opcodes.Op3F;
    _ = opcodes.Op40;
    _ = opcodes.Op41;
    _ = opcodes.Op42;
    _ = opcodes.Op43;
    _ = opcodes.Op44;
    _ = opcodes.Op45;
    _ = opcodes.Op46;
    _ = opcodes.Op47;
    _ = opcodes.Op48;
    _ = opcodes.Op49;
    _ = opcodes.Op4A;
    _ = opcodes.Op50;
    _ = opcodes.Op51;
    _ = opcodes.Op52;
    _ = opcodes.Op53;
    _ = opcodes.Op54;
    _ = opcodes.Op55;
    _ = opcodes.Op56;
    _ = opcodes.Op57;
    _ = opcodes.Op58;
    _ = opcodes.Op59;
    _ = opcodes.Op5A;
    _ = opcodes.Op5B;
    _ = opcodes.Op5C;
    _ = opcodes.Op5D;
    _ = opcodes.Op5E;
    _ = opcodes.Op5F;
    
    // Test PUSH operations
    _ = opcodes.Op60;
    _ = opcodes.Op61;
    _ = opcodes.Op62;
    _ = opcodes.Op63;
    _ = opcodes.Op64;
    _ = opcodes.Op65;
    _ = opcodes.Op66;
    _ = opcodes.Op67;
    _ = opcodes.Op68;
    _ = opcodes.Op69;
    _ = opcodes.Op6A;
    _ = opcodes.Op6B;
    _ = opcodes.Op6C;
    _ = opcodes.Op6D;
    _ = opcodes.Op6E;
    _ = opcodes.Op6F;
    _ = opcodes.Op70;
    _ = opcodes.Op71;
    _ = opcodes.Op72;
    _ = opcodes.Op73;
    _ = opcodes.Op74;
    _ = opcodes.Op75;
    _ = opcodes.Op76;
    _ = opcodes.Op77;
    _ = opcodes.Op78;
    _ = opcodes.Op79;
    _ = opcodes.Op7A;
    _ = opcodes.Op7B;
    _ = opcodes.Op7C;
    _ = opcodes.Op7D;
    _ = opcodes.Op7E;
    _ = opcodes.Op7F;
    
    // Test DUP operations
    _ = opcodes.Op80;
    _ = opcodes.Op81;
    _ = opcodes.Op82;
    _ = opcodes.Op83;
    _ = opcodes.Op84;
    _ = opcodes.Op85;
    _ = opcodes.Op86;
    _ = opcodes.Op87;
    _ = opcodes.Op88;
    _ = opcodes.Op89;
    _ = opcodes.Op8A;
    _ = opcodes.Op8B;
    _ = opcodes.Op8C;
    _ = opcodes.Op8D;
    _ = opcodes.Op8E;
    _ = opcodes.Op8F;
    
    // Test SWAP operations
    _ = opcodes.Op90;
    _ = opcodes.Op91;
    _ = opcodes.Op92;
    _ = opcodes.Op93;
    _ = opcodes.Op94;
    _ = opcodes.Op95;
    _ = opcodes.Op96;
    _ = opcodes.Op97;
    _ = opcodes.Op98;
    _ = opcodes.Op99;
    _ = opcodes.Op9A;
    _ = opcodes.Op9B;
    _ = opcodes.Op9C;
    _ = opcodes.Op9D;
    _ = opcodes.Op9E;
    _ = opcodes.Op9F;
    
    // Test LOG operations
    _ = opcodes.OpA0;
    _ = opcodes.OpA1;
    _ = opcodes.OpA2;
    _ = opcodes.OpA3;
    _ = opcodes.OpA4;
    
    // Test system operations
    _ = opcodes.OpF0;
    _ = opcodes.OpF1;
    _ = opcodes.OpF2;
    _ = opcodes.OpF3;
    _ = opcodes.OpF4;
    _ = opcodes.OpF5;
    _ = opcodes.OpFA;
    _ = opcodes.OpFD;
    _ = opcodes.OpFE;
    _ = opcodes.OpFF;
    
    // Test fusion operations
    _ = opcodes.Op100;
    _ = opcodes.Op101;
    _ = opcodes.Op102;
    _ = opcodes.Op103;
    _ = opcodes.Op104;
    _ = opcodes.Op105;
    _ = opcodes.Op106;
    _ = opcodes.Op107;
    _ = opcodes.Op108;
    _ = opcodes.Op109;
    _ = opcodes.Op10A;
    _ = opcodes.Op10B;
    _ = opcodes.Op10C;
    _ = opcodes.Op10D;
    _ = opcodes.Op10E;
    _ = opcodes.Op10F;
    _ = opcodes.Op110;
    _ = opcodes.Op111;
    _ = opcodes.Op112;
    _ = opcodes.Op113;
    _ = opcodes.Op114;
    _ = opcodes.Op115;
    _ = opcodes.Op116;
    _ = opcodes.Op117;
    _ = opcodes.Op118;
    _ = opcodes.Op119;
    _ = opcodes.Op11A;
    _ = opcodes.Op11B;
    _ = opcodes.Op11C;
    _ = opcodes.Op11D;
    _ = opcodes.Op11E;
}