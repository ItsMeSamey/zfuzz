const engine = @import("engine");

pub const Index = engine.Index;

pub fn init(allocator: @import("std").mem.Allocator, values: []const []const u8) @import("std").mem.Allocator.Error!Index {
    return engine.init(allocator, values);
}

test {
    _ = engine;
}
