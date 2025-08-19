const std = @import("std");

test "extract runtime code from 10k hashes bytecode" {
    // Full bytecode from the file
    const full_hex = "6080604052348015600e575f5ffd5b50609780601a5f395ff3fe6080604052348015600e575f5ffd5b50600436106026575f3560e01c806330627b7c14602a575b5f5ffd5b60306032565b005b5f5b614e20811015605e5760408051602081018390520160408051601f19818403019052526001016034565b5056fea26469706673582212202c247f39d615d7f66942cd6ed505d8ea34fbfcbe16ac875ed08c4a9c229325f364736f6c634300081e0033";
    
    
    // Find the runtime code marker (0xff3fe)
    if (std.mem.indexOf(u8, full_hex, "ff3fe")) |idx| {
        const runtime_hex = full_hex[idx + 5..]; // Skip "ff3fe"
        
        // The runtime code should be:
        // 6080604052... up to ...5056fe (the actual contract logic)
        const runtime_end = std.mem.indexOf(u8, runtime_hex, "a264697066735822") orelse runtime_hex.len;
        const clean_runtime = runtime_hex[0..runtime_end];
    } else {
    }
    
    // Let's also decode the constructor to understand what it does
    const constructor_hex = "6080604052348015600e575f5ffd5b50609780601a5f395ff3fe";
}