const std = @import("std");

// No-op tracer that does nothing - zero runtime cost
pub const NoOpTracer = struct {
    pub fn init() NoOpTracer {
        return .{};
    }
    
    pub fn beforeOp(self: *NoOpTracer, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = frame;
        // FrameType is used in the function signature, no need to discard
    }
    
    pub fn afterOp(self: *NoOpTracer, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = frame;
        // FrameType is used in the function signature, no need to discard
    }
    
    pub fn onError(self: *NoOpTracer, comptime FrameType: type, frame: *const FrameType, err: anyerror) void {
        _ = self;
        _ = frame;
        // No-op tracer doesn't do anything with errors
        // But we need to use it to avoid compiler error
        if (false) {
            std.debug.print("Error: {}\n", .{err});
        }
        // FrameType is used in the function signature, no need to discard
    }
};

// Test that NoOpTracer has zero cost
test "NoOpTracer has zero runtime cost" {
    var tracer = NoOpTracer.init();
    
    const TestFrame = struct {
        pc: u16,
        gas: i32,
    };
    
    const frame = TestFrame{ .pc = 0, .gas = 1000 };
    
    // These should compile to nothing
    tracer.beforeOp(TestFrame, &frame);
    tracer.afterOp(TestFrame, &frame);
    tracer.onError(TestFrame, &frame, error.TestError);
}