const std = @import("std");
const zigc_zig = @import("./zigc.zig");
const Zigc = zigc_zig.Zigc;

// ═══════════════════════════════════════════════════════════════════════════
// Basic Zone Tests
// ═══════════════════════════════════════════════════════════════════════════

test "basic hot zone usage" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const alloc = zigc.allocator(.hot);
    const buf = try alloc.alloc(u8, 100);
    defer alloc.free(buf);

    try std.testing.expectEqual(@as(usize, 1), zigc.snapshot(.hot).allocs);
    try std.testing.expectEqual(@as(usize, 100), zigc.snapshot(.hot).bytes_allocated);
}

test "hot zone guard detects balanced usage" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    {
        var guard = zigc.zoneGuard(.hot);
        defer guard.deinit(); // Should not panic

        const alloc = zigc.allocator(.hot);
        const buf = try alloc.alloc(u8, 64);
        alloc.free(buf);
    }
}

test "warm zone arena semantics" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Allocate without freeing
    _ = try warm.alloc(u8, 100);
    _ = try warm.alloc(u8, 200);

    try std.testing.expectEqual(@as(usize, 2), zigc.snapshot(.warm).allocs);
    try std.testing.expectEqual(@as(usize, 300), zigc.snapshot(.warm).bytes_allocated);

    // Reset clears everything
    warm.reset();

    const warm_stats = zigc.snapshot(.warm);
    try std.testing.expect(warm_stats.isBalanced());
    try std.testing.expectEqual(@as(usize, 2), warm_stats.allocs);
    try std.testing.expectEqual(@as(usize, 300), warm_stats.bytes_allocated);
}

test "cold zone persists until deinit" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });

    const warm = zigc.allocator(.warm);
    const alloc = zigc.allocator(.cold);
    _ = try alloc.alloc(u8, 500);

    try std.testing.expectEqual(@as(usize, 1), zigc.snapshot(.cold).allocs);

    // Cold zone survives warm reset
    warm.reset();
    try std.testing.expectEqual(@as(usize, 1), zigc.snapshot(.cold).allocs);

    zigc.deinit();
}

test "zone guard leak info" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    var guard = zigc.zoneGuard(.hot);

    const alloc = zigc.allocator(.hot);
    const buf = try alloc.alloc(u8, 128);

    // Before freeing, there should be a leak detected
    const leak_info = guard.checkLeak();
    try std.testing.expect(leak_info != null);
    try std.testing.expectEqual(@as(isize, 1), leak_info.?.allocs_leaked);
    try std.testing.expectEqual(@as(isize, 128), leak_info.?.bytes_leaked);

    // After freeing, no leak
    alloc.free(buf);
    const no_leak = guard.checkLeak();
    try std.testing.expect(no_leak == null);

    guard.deinit();
}

test "zone allocators expose reset and deinit" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);
    const cold = zigc.allocator(.cold);

    _ = try warm.alloc(u8, 64);
    _ = try cold.alloc(u8, 32);

    warm.reset();
    try std.testing.expect(zigc.snapshot(.warm).isBalanced());

    _ = try cold.alloc(u8, 128);
    cold.reset();
    try std.testing.expect(zigc.snapshot(.cold).isBalanced());

    _ = try cold.alloc(u8, 16);

    cold.deinit();
    try std.testing.expectEqual(@as(usize, 0), zigc.snapshot(.cold).allocs);

    warm.deinit();
    try std.testing.expectEqual(@as(usize, 0), zigc.snapshot(.warm).allocs);
}

// ═══════════════════════════════════════════════════════════════════════════
// Memory Budget Tests
// ═══════════════════════════════════════════════════════════════════════════

test "memory budgets: warm zone limit" {
    const limit = 10 * 1024; // 10KB limit
    var zigc = Zigc.init(std.testing.allocator, .{
        .debug = true,
        .warm_limit = limit,
    });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Should succeed - under budget
    const buf1 = try warm.alloc(u8, 4096);
    try std.testing.expect(buf1.len == 4096);

    // Should succeed - still under budget
    const buf2 = try warm.alloc(u8, 4096);
    try std.testing.expect(buf2.len == 4096);

    // Should fail - would exceed budget (8192 + 4096 > 10240)
    const result = warm.alloc(u8, 4096);
    try std.testing.expectError(error.OutOfMemory, result);

    // After reset, budget is available again
    warm.reset();
    const buf3 = try warm.alloc(u8, 8192);
    try std.testing.expect(buf3.len == 8192);
}

test "memory budgets: cold zone limit" {
    const limit = 16 * 1024; // 16KB limit
    var zigc = Zigc.init(std.testing.allocator, .{
        .debug = true,
        .cold_limit = limit,
    });
    defer zigc.deinit();

    const cold = zigc.allocator(.cold);

    // Fill up to limit
    const buf1 = try cold.alloc(u8, 8192);
    const buf2 = try cold.alloc(u8, 8192);
    try std.testing.expect(buf1.len == 8192);
    try std.testing.expect(buf2.len == 8192);

    // Should fail - at budget
    const result = cold.alloc(u8, 1);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "memory budgets: unlimited when limit = 0" {
    var zigc = Zigc.init(std.testing.allocator, .{
        .debug = true,
        .warm_limit = 0, // Unlimited
    });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Should succeed even with large allocation
    const buf = try warm.alloc(u8, 1024 * 1024); // 1MB
    try std.testing.expect(buf.len == 1024 * 1024);
}

test "budgets work with resize" {
    const limit = 5 * 1024; // 5KB limit
    var zigc = Zigc.init(std.testing.allocator, .{
        .debug = true,
        .warm_limit = limit,
    });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Allocate 4KB
    const buf = try warm.alloc(u8, 4096);
    try std.testing.expect(buf.len == 4096);

    // Try to resize to 6KB (would exceed budget)
    const can_resize = warm.resize(buf, 6144);
    try std.testing.expect(!can_resize); // Should fail
}

test "memory budgets enforced without debug" {
    const limit = 1024; // 1KB limit
    var zigc = Zigc.init(std.testing.allocator, .{
        .debug = false,
        .warm_limit = limit,
    });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Under budget
    const a = try warm.alloc(u8, 800);
    try std.testing.expect(a.len == 800);

    // This would exceed limit (800 + 400 > 1024)
    const result = warm.alloc(u8, 400);
    try std.testing.expectError(error.OutOfMemory, result);

    warm.reset();
    // Budget should be available again
    const b = try warm.alloc(u8, 1024);
    try std.testing.expect(b.len == 1024);
}

test "stale allocators panic after deinit" {
    if (!@hasDecl(std.testing, "expectPanic")) return; // Zig <=0.10 lacks expectPanic

    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);
    warm.deinit();

    try std.testing.expectPanic("deinitialized", struct {
        fn run() void {
            _ = warm.alloc(u8, 1) catch unreachable;
        }
    }.run);
}

// ═══════════════════════════════════════════════════════════════════════════
// High-Water Mark & Metrics Tests
// ═══════════════════════════════════════════════════════════════════════════

test "high-water marks: tracks peak usage" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Initial state
    var m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 0), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 0), m.high_water_bytes);

    // Allocate 1KB
    _ = try warm.alloc(u8, 1024);
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 1024), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 1024), m.high_water_bytes);

    // Allocate another 2KB (total 3KB)
    _ = try warm.alloc(u8, 2048);
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 3072), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 3072), m.high_water_bytes);

    // Reset (current goes to 0, high-water stays at peak)
    warm.reset();
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 0), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 3072), m.high_water_bytes); // Peak preserved

    // Allocate 1KB (less than previous peak)
    _ = try warm.alloc(u8, 1024);
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 1024), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 3072), m.high_water_bytes); // Still old peak

    // Allocate 4KB (new peak)
    warm.reset();
    _ = try warm.alloc(u8, 4096);
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 4096), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 4096), m.high_water_bytes); // New peak
}

test "high-water marks work across all zones" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const hot = zigc.allocator(.hot);
    const warm = zigc.allocator(.warm);
    const cold = zigc.allocator(.cold);

    // Hot zone
    const hot_buf = try hot.alloc(u8, 512);
    defer hot.free(hot_buf);
    var m = zigc.metrics(.hot);
    try std.testing.expectEqual(@as(usize, 512), m.high_water_bytes);

    // Warm zone
    _ = try warm.alloc(u8, 1024);
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 1024), m.high_water_bytes);

    // Cold zone
    _ = try cold.alloc(u8, 2048);
    m = zigc.metrics(.cold);
    try std.testing.expectEqual(@as(usize, 2048), m.high_water_bytes);
}

test "metrics: reset count tracking" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Initial reset count
    var m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 0), m.reset_count);

    // Reset once
    warm.reset();
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 1), m.reset_count);

    // Reset again
    warm.reset();
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 2), m.reset_count);

    // Multiple resets
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        warm.reset();
    }
    m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 12), m.reset_count);
}

test "metrics: all fields populated correctly" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Make some allocations
    _ = try warm.alloc(u8, 100);
    _ = try warm.alloc(u8, 200);
    _ = try warm.alloc(u8, 300);

    const m = zigc.metrics(.warm);
    try std.testing.expectEqual(@as(usize, 600), m.current_bytes);
    try std.testing.expectEqual(@as(usize, 600), m.high_water_bytes);
    try std.testing.expectEqual(@as(usize, 3), m.total_allocs);
    try std.testing.expectEqual(@as(usize, 0), m.total_frees); // Arena doesn't track individual frees
    try std.testing.expectEqual(@as(usize, 0), m.reset_count);
    try std.testing.expectEqual(@as(usize, 3), m.current_allocs);
}

// ═══════════════════════════════════════════════════════════════════════════
// Reset Mode Tests
// ═══════════════════════════════════════════════════════════════════════════

test "reset with retain_capacity mode" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Allocate some memory
    _ = try warm.alloc(u8, 1024);
    _ = try warm.alloc(u8, 2048);

    const before_reset = zigc.snapshot(.warm);
    try std.testing.expectEqual(@as(usize, 2), before_reset.allocs);

    // Reset retaining capacity (default)
    warm.reset();

    const after_reset = zigc.snapshot(.warm);
    try std.testing.expect(after_reset.isBalanced());

    // Allocate again - should reuse capacity
    _ = try warm.alloc(u8, 512);
    const after_realloc = zigc.snapshot(.warm);
    try std.testing.expectEqual(@as(usize, 3), after_realloc.allocs);
}

test "reset with release mode" {
    var zigc = Zigc.init(std.testing.allocator, .{ .debug = true });
    defer zigc.deinit();

    const warm = zigc.allocator(.warm);

    // Allocate some memory
    _ = try warm.alloc(u8, 1024);
    _ = try warm.alloc(u8, 2048);

    const before_reset = zigc.snapshot(.warm);
    try std.testing.expectEqual(@as(usize, 2), before_reset.allocs);

    // Reset and release memory
    warm.resetMode(.release);

    const after_reset = zigc.snapshot(.warm);
    try std.testing.expect(after_reset.isBalanced());

    // Arena should be reinitialized and ready for use
    _ = try warm.alloc(u8, 512);
    const after_realloc = zigc.snapshot(.warm);
    try std.testing.expectEqual(@as(usize, 3), after_realloc.allocs);
}
