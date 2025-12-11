const std = @import("std");
const Zigc = @import("zigc.zig").Zigc;

test "arraylist warm allocator survives reset when properly deinitialized" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm_alloc = zigc.allocator(.warm).asAllocator();

    // First lifetime
    {
        var list = std.ArrayList(u32).empty;
        defer list.deinit(warm_alloc);

        try list.appendSlice(warm_alloc, &[_]u32{ 1, 2, 3, 4 });
        try std.testing.expectEqual(@as(usize, 4), list.items.len);
        try std.testing.expectEqual(@as(u32, 1), list.items[0]);
    }

    // Reset arena; capacity is retained but contents are gone.
    zigc.reset(.warm, .retain_capacity);

    // Second lifetime reuses the same allocator safely.
    {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(warm_alloc);

        try list.appendSlice(warm_alloc, "hello");
        try std.testing.expectEqualStrings("hello", list.items);
    }
}

test "arraylist warm allocator respects budget even with debug disabled" {
    const limit = 256; // bytes
    var zigc = Zigc.init(std.testing.allocator, .{
        .debug = false,
        .warm_limit = limit,
    });
    defer zigc.deinit();

    const warm_alloc = zigc.allocator(.warm).asAllocator();
    var list = std.ArrayList(u8).empty;
    defer list.deinit(warm_alloc);

    // ~128 bytes ok (capacity will round to cache-line sized chunk)
    try list.appendNTimes(warm_alloc, 0xAA, 128);
    try std.testing.expectEqual(@as(usize, 128), list.items.len);

    // Next 200 should exceed the 256-byte budget and fail
    const res = list.appendNTimes(warm_alloc, 0xBB, 200);
    try std.testing.expectError(error.OutOfMemory, res);
}

test "arraylist in cold zone persists across warm reset" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm_alloc = zigc.allocator(.warm).asAllocator();
    const cold_alloc = zigc.allocator(.cold).asAllocator();

    var cold_list = std.ArrayList(u16).empty;
    defer cold_list.deinit(cold_alloc);

    try cold_list.appendSlice(cold_alloc, &[_]u16{ 10, 20, 30 });
    try std.testing.expectEqual(@as(usize, 3), cold_list.items.len);

    // Warm activity and reset should not affect cold_list contents.
    {
        var warm_list = std.ArrayList(u8).empty;
        defer warm_list.deinit(warm_alloc);
        try warm_list.appendSlice(warm_alloc, "temp");
    }
    zigc.reset(.warm, .retain_capacity);

    try std.testing.expectEqual(@as(usize, 3), cold_list.items.len);
    try std.testing.expectEqual(@as(u16, 30), cold_list.items[2]);
}

test "arraylist operations panic after zone deinit" {
    if (!@hasDecl(std.testing, "expectPanic")) return; // older Zig

    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);
    const warm_alloc = warm.asAllocator();

    var list = std.ArrayList(u8).empty;
    defer list.deinit(warm_alloc);

    warm.deinit(); // invalidate zone

    try std.testing.expectPanic("deinitialized", struct {
        fn run(list_ptr: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            // append triggers allocator usage which should panic
            list_ptr.*.append(alloc, 42) catch unreachable;
        }
    }.run, &list, warm_alloc);
}
