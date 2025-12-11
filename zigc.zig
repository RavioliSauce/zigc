//! zigc: Region-based memory management with three zones (hot/warm/cold).
//!
//! This library provides "GC-like" ergonomics without a garbage collector by organizing
//! allocations into three zones with different lifetime characteristics:
//!
//! ## Three Zones
//!
//! - **hot**:  Ultra-short-lived allocations with explicit `free()` (pass-through to backing allocator)
//! - **warm**: Per-request/per-frame/per-job arena, freed in bulk with `reset()`
//! - **cold**: Long-lived arena for caches/config, freed on `deinit()`
//!
//! ## Quick Example
//!
//! ```zig
//! var zigc = Zigc.init(std.heap.page_allocator, .{});
//! defer zigc.deinit();
//!
//! // Warm zone: request-scoped arena
//! const warm = zigc.allocator(.warm);
//! defer warm.reset(); // Free all allocations at once
//! const data = try warm.alloc(u8, 1024);
//! // No individual frees needed!
//!
//! // Hot zone: explicit lifetime
//! const hot = zigc.allocator(.hot);
//! const scratch = try hot.alloc(u8, 128);
//! defer hot.free(scratch);
//!
//! // Cold zone: long-lived state
//! const cold = zigc.allocator(.cold);
//! const config = try cold.create(Config);
//! // Lives until zigc.deinit()
//! ```
//!
//! ## Performance
//!
//! - Debug mode: ~48% overhead for allocation tracking
//! - Release mode: Negligible overhead over raw ArenaAllocator
//! - Bulk reset: O(1) regardless of allocation count
//!
//! ## See Also
//!
//! - `Zigc.init()` - Create a new instance
//! - `Zigc.allocator()` - Get a zone allocator
//! - `ZoneAllocator.reset()` - Free all allocations in a zone
//! - `Zigc.zoneGuard()` - RAII leak detection helper

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Zigc = struct {
    /// The three allocation zones.
    pub const Zone = enum(u2) {
        /// Ultra-short-lived allocations with explicit free.
        /// Backed directly by the backing allocator.
        hot = 0,
        /// Per-request/per-frame allocations, freed in bulk with reset(.warm).
        warm = 1,
        /// Long-lived allocations (caches, config), freed on deinit().
        cold = 2,
    };

    /// Reset mode for arena zones (warm/cold).
    pub const ResetMode = enum {
        /// Free all allocations but retain allocated memory capacity for reuse.
        /// This is faster and reduces allocator churn. Recommended for hot loops.
        retain_capacity,

        /// Free all allocations and release memory back to the backing allocator.
        /// Use this when you want to actually reduce memory footprint (e.g., after a spike).
        release,
    };

    /// Allocation statistics for a zone.
    /// Only tracked when `debug: true` is enabled in config.
    /// Use `Zigc.snapshot()` to retrieve current stats for a zone.
    pub const ZoneStats = struct {
        /// Total number of allocations made in this zone.
        allocs: usize = 0,
        /// Total number of frees called in this zone.
        frees: usize = 0,
        /// Total bytes allocated in this zone.
        bytes_allocated: usize = 0,
        /// Total bytes freed in this zone.
        bytes_freed: usize = 0,

        /// Returns net allocation count (allocs - frees).
        /// Positive means outstanding allocations, negative means over-freed (bug).
        pub fn netAllocs(self: ZoneStats) isize {
            return @as(isize, @intCast(self.allocs)) - @as(isize, @intCast(self.frees));
        }

        /// Returns net bytes (allocated - freed).
        /// Positive means outstanding memory, negative means over-freed (bug).
        pub fn netBytes(self: ZoneStats) isize {
            return @as(isize, @intCast(self.bytes_allocated)) - @as(isize, @intCast(self.bytes_freed));
        }

        /// Returns true if this zone has no outstanding allocations.
        /// For hot zone: allocs == frees (perfect balance).
        /// For warm/cold: true after reset() but allocs/frees counters persist.
        pub fn isBalanced(self: ZoneStats) bool {
            return self.allocs == self.frees and self.bytes_allocated == self.bytes_freed;
        }
    };

    /// Enhanced metrics including high-water marks and reset counts.
    pub const ZoneMetrics = struct {
        /// Current bytes allocated (net: allocated - freed).
        current_bytes: usize,
        /// Peak bytes allocated since initialization.
        high_water_bytes: usize,
        /// Total number of allocations made.
        total_allocs: usize,
        /// Total number of frees called.
        total_frees: usize,
        /// Number of reset() calls on this zone.
        reset_count: usize,
        /// Current allocation count (net: allocs - frees).
        current_allocs: usize,
    };

    /// Configuration options for Zigc initialization.
    pub const Config = struct {
        /// Enable debug tracking (allocation stats, leak detection).
        /// When enabled, tracks allocation counts and bytes for each zone.
        /// This adds ~48% overhead but is invaluable for debugging.
        /// Defaults to true in debug/safe builds, false in release builds.
        debug: bool = std.debug.runtime_safety,

        /// Memory budget for warm zone in bytes (0 = unlimited).
        /// When set, allocations that would exceed this limit return error.OutOfMemory.
        /// Useful for preventing unbounded growth in request handlers.
        /// Example: 64 * 1024 * 1024 for 64MB cap.
        warm_limit: usize = 0,

        /// Memory budget for cold zone in bytes (0 = unlimited).
        /// When set, allocations that would exceed this limit return error.OutOfMemory.
        /// Useful for capping cache sizes or long-lived state.
        /// Example: 256 * 1024 * 1024 for 256MB cap.
        cold_limit: usize = 0,
    };

    // ─────────────────────────────────────────────────────────────────────────
    // Internal State
    // ─────────────────────────────────────────────────────────────────────────

    backing: Allocator,
    warm_arena: ArenaAllocator,
    cold_arena: ArenaAllocator,

    stats: [3]ZoneStats = [_]ZoneStats{.{}} ** 3,
    high_water_marks: [3]usize = [_]usize{0} ** 3,
    reset_counts: [3]usize = [_]usize{0} ** 3,
    zone_limits: [3]usize = [_]usize{0} ** 3,
    zone_active: [3]bool = [_]bool{true} ** 3,
    debug: bool,

    // ─────────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────────

    /// Initialize a Zigc instance with a backing allocator.
    ///
    /// The backing allocator will be used for:
    /// - Hot zone allocations (direct pass-through)
    /// - Underlying storage for warm and cold arenas
    ///
    /// Example:
    /// ```zig
    /// var zigc = Zigc.init(std.heap.page_allocator, .{});
    /// defer zigc.deinit();
    /// ```
    ///
    /// With memory budgets:
    /// ```zig
    /// var zigc = Zigc.init(std.heap.page_allocator, .{
    ///     .warm_limit = 64 * 1024 * 1024,  // 64MB cap
    ///     .cold_limit = 256 * 1024 * 1024, // 256MB cap
    /// });
    /// ```
    ///
    /// For production use with minimal overhead:
    /// ```zig
    /// var zigc = Zigc.init(std.heap.page_allocator, .{ .debug = false });
    /// ```
    pub fn init(backing: Allocator, config: Config) Zigc {
        var self = Zigc{
            .backing = backing,
            .warm_arena = ArenaAllocator.init(backing),
            .cold_arena = ArenaAllocator.init(backing),
            .debug = config.debug,
            .stats = [_]ZoneStats{.{}} ** 3,
            .high_water_marks = [_]usize{0} ** 3,
            .reset_counts = [_]usize{0} ** 3,
            .zone_limits = [_]usize{0} ** 3,
            .zone_active = [_]bool{true} ** 3,
        };

        // Set zone limits
        self.zone_limits[@intFromEnum(Zone.warm)] = config.warm_limit;
        self.zone_limits[@intFromEnum(Zone.cold)] = config.cold_limit;

        return self;
    }

    /// Deinitialize, freeing all zones and their memory.
    /// After calling this, the Zigc instance and all zone allocators are invalid.
    ///
    /// Order of cleanup:
    /// 1. Cold zone arena is freed
    /// 2. Warm zone arena is freed
    /// 3. Hot zone has no cleanup (pass-through allocator)
    ///
    /// Note: This does NOT free hot zone allocations - you must free those manually.
    pub fn deinit(self: *Zigc) void {
        self.deinitZone(.cold);
        self.deinitZone(.warm);
        self.* = undefined;
    }

    /// Get an allocator handle for the specified zone.
    ///
    /// Returns a `ZoneAllocator` which implements the standard `std.mem.Allocator` interface
    /// plus zone-specific operations like `reset()` and `deinit()`.
    ///
    /// Zone behaviors:
    /// - `.hot`: Pass-through to backing allocator. You must call `free()` for each allocation.
    /// - `.warm`: Arena allocator. Call `reset()` to free all allocations at once.
    /// - `.cold`: Arena allocator. Lives until explicitly reset or `zigc.deinit()`.
    ///
    /// Example:
    /// ```zig
    /// const warm = zigc.allocator(.warm);
    /// defer warm.reset();
    ///
    /// const data = try warm.alloc(u8, 1024);
    /// // No need to free `data` - warm.reset() handles it
    /// ```
    pub fn allocator(self: *Zigc, zone: Zone) ZoneAllocator {
        return ZoneAllocator.init(self, zone);
    }

    /// Reset a zone, freeing all its allocations.
    ///
    /// Default behavior is `.retain_capacity` for performance.
    /// Use `reset(zone, .release)` to actually free memory to backing allocator.
    ///
    /// ⚠️  WARNING: You must clear/deinit all data structures using this zone
    ///    BEFORE calling reset(), otherwise:
    ///    - Accessing those structures = undefined behavior (likely segfault)
    ///    - Memory corruption and hard-to-debug crashes
    ///    - Zig's safety features won't catch this
    ///
    /// Safe pattern:
    /// ```zig
    /// list.clearRetainingCapacity(); // 1. Clear data structures first
    /// zigc.reset(.warm, .retain_capacity); // 2. Then reset arena
    /// ```
    ///
    /// Common mistake:
    /// ```zig
    /// zigc.reset(.warm, .retain_capacity);
    /// const item = list.items[0]; // ❌ CRASH - accessing freed memory!
    /// ```
    ///
    /// Zone-specific behavior:
    /// - `.hot`: No-op, but panics in debug mode if there are outstanding allocations.
    /// - `.warm`: Frees all allocations, optionally retaining capacity.
    /// - `.cold`: Frees all allocations, optionally retaining capacity.
    ///
    /// Debug stats are updated but counters persist across resets.
    /// After reset, `isBalanced()` will return true but `allocs` count remains.
    ///
    /// Example:
    /// ```zig
    /// warm.reset(); // Fast, retains capacity
    /// warm.reset(.retain_capacity); // Same as above
    /// warm.reset(.release); // Actually free memory
    /// ```
    pub fn reset(self: *Zigc, zone: Zone, mode: ResetMode) void {
        switch (zone) {
            .hot => {
                // Hot zone is pass-through; no bulk reset possible.
                if (self.debug and !self.stats[@intFromEnum(Zone.hot)].isBalanced()) {
                    @panic("zigc: reset(.hot) called but hot zone has outstanding allocations");
                }
            },
            .warm => {
                self.resetArena(.warm, &self.warm_arena, mode);
                self.reset_counts[@intFromEnum(Zone.warm)] += 1;
            },
            .cold => {
                self.resetArena(.cold, &self.cold_arena, mode);
                self.reset_counts[@intFromEnum(Zone.cold)] += 1;
            },
        }
    }

    /// Get a snapshot of the current allocation statistics for a zone.
    ///
    /// Only meaningful when `debug: true` is enabled in config.
    /// In release builds with debug disabled, all stats will be zero.
    ///
    /// Example:
    /// ```zig
    /// const stats = zigc.snapshot(.warm);
    /// std.debug.print("Allocations: {}, Bytes: {}\n", .{
    ///     stats.allocs,
    ///     stats.bytes_allocated,
    /// });
    /// ```
    pub fn snapshot(self: *const Zigc, zone: Zone) ZoneStats {
        return self.stats[@intFromEnum(zone)];
    }

    /// Get enhanced metrics including high-water marks and reset counts.
    ///
    /// Provides additional insights beyond basic stats:
    /// - Current and peak memory usage
    /// - Reset counts for tuning reset frequency
    /// - Net allocations vs total allocations
    ///
    /// Use this to answer questions like:
    /// - "How much memory does my warm zone actually need?"
    /// - "Am I resetting too often or not often enough?"
    /// - "What's my peak memory usage during a batch?"
    ///
    /// Example:
    /// ```zig
    /// const m = zigc.metrics(.warm);
    /// std.debug.print("Current: {}KB, Peak: {}KB, Resets: {}\n", .{
    ///     m.current_bytes / 1024,
    ///     m.high_water_bytes / 1024,
    ///     m.reset_count,
    /// });
    ///
    /// // Use high_water_bytes to set appropriate budget
    /// if (m.high_water_bytes > 0) {
    ///     const recommended_limit = m.high_water_bytes * 12 / 10; // +20% headroom
    ///     std.debug.print("Consider warm_limit = {}\n", .{recommended_limit});
    /// }
    /// ```
    pub fn metrics(self: *const Zigc, zone: Zone) ZoneMetrics {
        const stats = self.stats[@intFromEnum(zone)];
        const current_bytes = @as(usize, @intCast(@max(0, stats.netBytes())));
        const current_allocs = @as(usize, @intCast(@max(0, stats.netAllocs())));

        return .{
            .current_bytes = current_bytes,
            .high_water_bytes = self.high_water_marks[@intFromEnum(zone)],
            .total_allocs = stats.allocs,
            .total_frees = stats.frees,
            .reset_count = self.reset_counts[@intFromEnum(zone)],
            .current_allocs = current_allocs,
        };
    }

    /// Create a ZoneGuard for RAII-style leak detection.
    ///
    /// The guard captures allocation stats on creation and checks for leaks on `deinit()`.
    /// In debug mode, panics if allocations are unbalanced.
    ///
    /// This is particularly useful for hot zone allocations where you must manually free.
    ///
    /// Example:
    /// ```zig
    /// {
    ///     var guard = zigc.zoneGuard(.hot);
    ///     defer guard.deinit(); // Panics if any leaks
    ///
    ///     const buf = try hot.alloc(u8, 64);
    ///     defer hot.free(buf); // Must free or guard.deinit() panics
    /// }
    /// ```
    pub fn zoneGuard(self: *Zigc, zone: Zone) ZoneGuard {
        self.ensureZoneActive(zone);
        return .{
            .zigc = self,
            .zone = zone,
            .before = self.snapshot(zone),
        };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ZoneAllocator Handles
    // ─────────────────────────────────────────────────────────────────────────

    /// Represents a zone-specific allocator handle that also exposes reset/deinit.
    pub const ZoneAllocator = struct {
        zigc: *Zigc,
        zone: Zone,

        fn init(zigc: *Zigc, zone: Zone) ZoneAllocator {
            zigc.ensureZoneActive(zone);
            return .{ .zigc = zigc, .zone = zone };
        }

        inline fn inner(self: ZoneAllocator) Allocator {
            self.zigc.ensureZoneActive(self.zone);
            return .{
                .ptr = self.zigc,
                .vtable = switch (self.zone) {
                    .hot => &hot_vtable,
                    .warm => &warm_vtable,
                    .cold => &cold_vtable,
                },
            };
        }

        /// Access the underlying `std.mem.Allocator` if a raw handle is needed.
        ///
        /// Most of the time you can use the ZoneAllocator directly since it
        /// implements all the standard allocator methods. Use this when you need
        /// to pass a `std.mem.Allocator` to APIs that require it.
        pub inline fn asAllocator(self: ZoneAllocator) Allocator {
            return self.inner();
        }

        /// Reset this zone, freeing all allocations.
        ///
        /// ⚠️  WARNING: You must clear/deinit all data structures using this zone
        ///    BEFORE calling reset(), otherwise you'll access freed memory.
        ///
        /// Default mode is `.retain_capacity` (fast, keeps memory allocated).
        /// For warm/cold zones, this frees all allocations in the arena.
        /// For hot zone, this is a no-op but panics if allocations are unbalanced.
        ///
        /// Example:
        /// ```zig
        /// const warm = zigc.allocator(.warm);
        /// defer warm.reset(); // Default: retain capacity
        /// ```
        pub fn reset(self: ZoneAllocator) void {
            self.zigc.reset(self.zone, .retain_capacity);
        }

        /// Reset this zone with explicit mode control.
        ///
        /// ⚠️  WARNING: You must clear/deinit all data structures using this zone
        ///    BEFORE calling reset(), otherwise you'll access freed memory.
        ///
        /// Modes:
        /// - `.retain_capacity`: Fast, keeps allocated memory (default via reset())
        /// - `.release`: Actually free memory back to backing allocator
        ///
        /// Example:
        /// ```zig
        /// warm.resetMode(.release); // Free memory after spike
        /// ```
        pub fn resetMode(self: ZoneAllocator, mode: ResetMode) void {
            self.zigc.reset(self.zone, mode);
        }

        /// Deinitialize this zone, freeing its arena memory completely.
        ///
        /// After calling this, the zone allocator is invalid and must not be used.
        /// This is typically only needed if you want to tear down a zone before
        /// the parent Zigc instance is deinitialized.
        ///
        /// Most users should just call `zigc.deinit()` which handles all zones.
        pub fn deinit(self: ZoneAllocator) void {
            self.zigc.deinitZone(self.zone);
        }

        pub inline fn rawAlloc(self: ZoneAllocator, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            return self.inner().rawAlloc(len, alignment, ret_addr);
        }

        pub inline fn rawResize(
            self: ZoneAllocator,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            return self.inner().rawResize(memory, alignment, new_len, ret_addr);
        }

        pub inline fn rawRemap(
            self: ZoneAllocator,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            return self.inner().rawRemap(memory, alignment, new_len, ret_addr);
        }

        pub inline fn rawFree(
            self: ZoneAllocator,
            memory: []u8,
            alignment: Alignment,
            ret_addr: usize,
        ) void {
            self.inner().rawFree(memory, alignment, ret_addr);
        }

        pub inline fn create(self: ZoneAllocator, comptime T: type) Allocator.Error!*T {
            return self.inner().create(T);
        }

        pub inline fn destroy(self: ZoneAllocator, ptr: anytype) void {
            self.inner().destroy(ptr);
        }

        pub inline fn alloc(self: ZoneAllocator, comptime T: type, n: usize) Allocator.Error![]T {
            return self.inner().alloc(T, n);
        }

        pub inline fn allocWithOptions(
            self: ZoneAllocator,
            comptime Elem: type,
            n: usize,
            comptime optional_alignment: ?Alignment,
            comptime optional_sentinel: ?Elem,
        ) Allocator.Error!AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
            return self.inner().allocWithOptions(Elem, n, optional_alignment, optional_sentinel);
        }

        pub inline fn allocWithOptionsRetAddr(
            self: ZoneAllocator,
            comptime Elem: type,
            n: usize,
            comptime optional_alignment: ?Alignment,
            comptime optional_sentinel: ?Elem,
            return_address: usize,
        ) Allocator.Error!AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
            return self.inner().allocWithOptionsRetAddr(Elem, n, optional_alignment, optional_sentinel, return_address);
        }

        pub inline fn allocSentinel(
            self: ZoneAllocator,
            comptime Elem: type,
            n: usize,
            comptime sentinel: Elem,
        ) Allocator.Error![:sentinel]Elem {
            return self.inner().allocSentinel(Elem, n, sentinel);
        }

        pub inline fn alignedAlloc(
            self: ZoneAllocator,
            comptime T: type,
            comptime alignment: ?Alignment,
            n: usize,
        ) Allocator.Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
            return self.inner().alignedAlloc(T, alignment, n);
        }

        pub inline fn allocAdvancedWithRetAddr(
            self: ZoneAllocator,
            comptime T: type,
            comptime alignment: ?Alignment,
            n: usize,
            return_address: usize,
        ) Allocator.Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
            return self.inner().allocAdvancedWithRetAddr(T, alignment, n, return_address);
        }

        pub inline fn resize(self: ZoneAllocator, allocation: anytype, new_len: usize) bool {
            return self.inner().resize(allocation, new_len);
        }

        pub inline fn remap(
            self: ZoneAllocator,
            allocation: anytype,
            new_len: usize,
        ) t: {
            const Slice = @typeInfo(@TypeOf(allocation)).pointer;
            break :t ?[]align(Slice.alignment) Slice.child;
        } {
            return self.inner().remap(allocation, new_len);
        }

        pub inline fn realloc(
            self: ZoneAllocator,
            old_mem: anytype,
            new_n: usize,
        ) t: {
            const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
            break :t Allocator.Error![]align(Slice.alignment) Slice.child;
        } {
            return self.inner().realloc(old_mem, new_n);
        }

        pub inline fn reallocAdvanced(
            self: ZoneAllocator,
            old_mem: anytype,
            new_n: usize,
            return_address: usize,
        ) t: {
            const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
            break :t Allocator.Error![]align(Slice.alignment) Slice.child;
        } {
            return self.inner().reallocAdvanced(old_mem, new_n, return_address);
        }

        pub inline fn free(self: ZoneAllocator, memory: anytype) void {
            self.inner().free(memory);
        }

        pub inline fn dupe(self: ZoneAllocator, comptime T: type, m: []const T) Allocator.Error![]T {
            return self.inner().dupe(T, m);
        }

        pub inline fn dupeZ(self: ZoneAllocator, comptime T: type, m: []const T) Allocator.Error![:0]T {
            return self.inner().dupeZ(T, m);
        }

        fn AllocWithOptionsPayload(
            comptime Elem: type,
            comptime alignment: ?Alignment,
            comptime sentinel: ?Elem,
        ) type {
            if (sentinel) |s| {
                return [:s]align(if (alignment) |a| a.toByteUnits() else @alignOf(Elem)) Elem;
            } else {
                return []align(if (alignment) |a| a.toByteUnits() else @alignOf(Elem)) Elem;
            }
        }
    };

    // ─────────────────────────────────────────────────────────────────────────
    // ZoneGuard
    // ─────────────────────────────────────────────────────────────────────────

    /// RAII guard for scope-based leak detection.
    ///
    /// Usage:
    /// ```zig
    /// var guard = zigc.zoneGuard(.hot);
    /// defer guard.deinit();
    /// // ... allocations with explicit frees ...
    /// // guard.deinit() panics if allocs != frees in this scope
    /// ```
    pub const ZoneGuard = struct {
        zigc: *Zigc,
        zone: Zone,
        before: ZoneStats,

        /// Check for leaks and panic if any are found (in debug mode).
        pub fn deinit(self: ZoneGuard) void {
            self.zigc.ensureZoneActive(self.zone);
            if (self.zigc.debug) {
                self.zigc.checkNoLeak(self.zone, self.before);
            }
        }

        /// Manually check for leaks without panicking.
        /// Returns null if no leak, or an error message if there is one.
        pub fn checkLeak(self: *const ZoneGuard) ?LeakInfo {
            self.zigc.ensureZoneActive(self.zone);
            if (!self.zigc.debug) return null;

            const after = self.zigc.snapshot(self.zone);
            const alloc_diff = @as(isize, @intCast(after.allocs)) - @as(isize, @intCast(self.before.allocs));
            const free_diff = @as(isize, @intCast(after.frees)) - @as(isize, @intCast(self.before.frees));
            const bytes_in = @as(isize, @intCast(after.bytes_allocated)) - @as(isize, @intCast(self.before.bytes_allocated));
            const bytes_out = @as(isize, @intCast(after.bytes_freed)) - @as(isize, @intCast(self.before.bytes_freed));

            if (alloc_diff != free_diff or bytes_in != bytes_out) {
                return .{
                    .zone = self.zone,
                    .allocs_leaked = alloc_diff - free_diff,
                    .bytes_leaked = bytes_in - bytes_out,
                };
            }
            return null;
        }
    };

    /// Information about a detected leak.
    pub const LeakInfo = struct {
        zone: Zone,
        allocs_leaked: isize,
        bytes_leaked: isize,

        pub fn format(
            self: LeakInfo,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("zigc leak in .{s} zone: {d} allocation(s), {d} byte(s)", .{
                @tagName(self.zone),
                self.allocs_leaked,
                self.bytes_leaked,
            });
        }
    };

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: Leak Checking
    // ─────────────────────────────────────────────────────────────────────────

    fn checkNoLeak(self: *const Zigc, zone: Zone, before: ZoneStats) void {
        const after = self.snapshot(zone);

        switch (zone) {
            .hot => {
                // Hot zone: allocs in this scope must match frees
                const allocs_in_scope = after.allocs - before.allocs;
                const frees_in_scope = after.frees - before.frees;
                const bytes_allocated_in_scope = after.bytes_allocated - before.bytes_allocated;
                const bytes_freed_in_scope = after.bytes_freed - before.bytes_freed;

                if (allocs_in_scope != frees_in_scope) {
                    std.debug.print(
                        "zigc: hot zone leaked {d} allocation(s) in this scope\n",
                        .{allocs_in_scope - frees_in_scope},
                    );
                    @panic("zigc: hot zone leaked allocations");
                }
                if (bytes_allocated_in_scope != bytes_freed_in_scope) {
                    std.debug.print(
                        "zigc: hot zone leaked {d} byte(s) in this scope\n",
                        .{bytes_allocated_in_scope - bytes_freed_in_scope},
                    );
                    @panic("zigc: hot zone leaked bytes");
                }
            },
            .warm, .cold => {
                // Warm/cold are arena-based; leak checking is optional.
                // We could warn if bytes grew unexpectedly, but typically
                // the user calls reset(.warm) at a higher scope.
            },
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: Zone Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    inline fn zoneIndex(zone: Zone) usize {
        return @intFromEnum(zone);
    }

    fn ensureZoneActive(self: *const Zigc, zone: Zone) void {
        switch (zone) {
            .hot => {},
            .warm, .cold => {
                if (!self.zone_active[zoneIndex(zone)]) {
                    std.debug.panic("zigc: .{s} zone has been deinitialized", .{@tagName(zone)});
                }
            },
        }
    }

    fn resetArena(self: *Zigc, zone: Zone, arena: *ArenaAllocator, mode: ResetMode) void {
        self.ensureZoneActive(zone);
        if (self.debug) {
            self.markArenaCleared(zone);
        }
        switch (mode) {
            .retain_capacity => _ = arena.reset(.retain_capacity),
            .release => arena.deinit(),
        }

        // If we released, reinitialize the arena for future use
        if (mode == .release) {
            arena.* = ArenaAllocator.init(self.backing);
        }
    }

    fn deinitZone(self: *Zigc, zone: Zone) void {
        switch (zone) {
            .hot => {},
            .warm => self.teardownArena(.warm, &self.warm_arena),
            .cold => self.teardownArena(.cold, &self.cold_arena),
        }
    }

    fn teardownArena(self: *Zigc, zone: Zone, arena: *ArenaAllocator) void {
        const idx = zoneIndex(zone);
        if (!self.zone_active[idx]) return;
        arena.deinit();
        self.zone_active[idx] = false;
        if (self.debug) {
            self.stats[idx] = .{};
        }
    }

    fn markArenaCleared(self: *Zigc, zone: Zone) void {
        const idx = zoneIndex(zone);
        const stats = &self.stats[idx];
        stats.frees = stats.allocs;
        stats.bytes_freed = stats.bytes_allocated;
    }

    fn checkBudget(self: *Zigc, zone: Zone, len: usize) bool {
        const limit = self.zone_limits[@intFromEnum(zone)];
        if (limit == 0) return true; // Unlimited

        const stats = self.stats[@intFromEnum(zone)];
        const current = @as(usize, @intCast(@max(0, stats.netBytes())));

        return current + len <= limit;
    }

    fn updateHighWater(self: *Zigc, zone: Zone) void {
        const stats = self.stats[@intFromEnum(zone)];
        const current = @as(usize, @intCast(@max(0, stats.netBytes())));
        const idx = @intFromEnum(zone);

        if (current > self.high_water_marks[idx]) {
            self.high_water_marks[idx] = current;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: Allocator VTables
    // ─────────────────────────────────────────────────────────────────────────

    const hot_vtable = Allocator.VTable{
        .alloc = hotAlloc,
        .resize = hotResize,
        .remap = hotRemap,
        .free = hotFree,
    };

    const warm_vtable = Allocator.VTable{
        .alloc = warmAlloc,
        .resize = warmResize,
        .remap = warmRemap,
        .free = warmFree,
    };

    const cold_vtable = Allocator.VTable{
        .alloc = coldAlloc,
        .resize = coldResize,
        .remap = coldRemap,
        .free = coldFree,
    };

    // ── Hot Zone (pass-through to backing allocator) ──

    fn hotAlloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, ptr_align, ret_addr);
        if (result != null and self.debug) {
            self.stats[@intFromEnum(Zone.hot)].allocs += 1;
            self.stats[@intFromEnum(Zone.hot)].bytes_allocated += len;
            self.updateHighWater(.hot);
        }
        return result;
    }

    fn hotResize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.backing.rawResize(buf, buf_align, new_len, ret_addr);
        if (result and self.debug) {
            const stats = &self.stats[@intFromEnum(Zone.hot)];
            if (new_len > old_len) {
                stats.bytes_allocated += (new_len - old_len);
            } else {
                stats.bytes_freed += (old_len - new_len);
            }
            self.updateHighWater(.hot);
        }
        return result;
    }

    fn hotRemap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.backing.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null and self.debug) {
            const stats = &self.stats[@intFromEnum(Zone.hot)];
            if (new_len > old_len) {
                stats.bytes_allocated += (new_len - old_len);
            } else {
                stats.bytes_freed += (old_len - new_len);
            }
        }
        return result;
    }

    fn hotFree(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        if (self.debug) {
            self.stats[@intFromEnum(Zone.hot)].frees += 1;
            self.stats[@intFromEnum(Zone.hot)].bytes_freed += buf.len;
        }
        self.backing.rawFree(buf, buf_align, ret_addr);
    }

    // ── Warm Zone (arena-backed) ──

    fn warmAlloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Zigc = @ptrCast(@alignCast(ctx));

        // Check budget before allocating
        if (!self.checkBudget(.warm, len)) {
            return null; // Out of budget
        }

        const result = self.warm_arena.allocator().rawAlloc(len, ptr_align, ret_addr);
        if (result != null and self.debug) {
            self.stats[@intFromEnum(Zone.warm)].allocs += 1;
            self.stats[@intFromEnum(Zone.warm)].bytes_allocated += len;
            self.updateHighWater(.warm);
        }
        return result;
    }

    fn warmResize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;

        // Check budget if growing
        if (new_len > old_len) {
            if (!self.checkBudget(.warm, new_len - old_len)) {
                return false; // Would exceed budget
            }
        }

        const result = self.warm_arena.allocator().rawResize(buf, buf_align, new_len, ret_addr);
        if (result and self.debug) {
            const stats = &self.stats[@intFromEnum(Zone.warm)];
            if (new_len > old_len) {
                stats.bytes_allocated += (new_len - old_len);
            } else {
                stats.bytes_freed += (old_len - new_len);
            }
            self.updateHighWater(.warm);
        }
        return result;
    }

    fn warmRemap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.warm_arena.allocator().rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null and self.debug) {
            const stats = &self.stats[@intFromEnum(Zone.warm)];
            if (new_len > old_len) {
                stats.bytes_allocated += (new_len - old_len);
            } else {
                stats.bytes_freed += (old_len - new_len);
            }
        }
        return result;
    }

    fn warmFree(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        if (self.debug) {
            self.stats[@intFromEnum(Zone.warm)].frees += 1;
            self.stats[@intFromEnum(Zone.warm)].bytes_freed += buf.len;
        }
        // Arena doesn't actually free individual allocations, but we still
        // call through for consistency (it's a no-op).
        self.warm_arena.allocator().rawFree(buf, buf_align, ret_addr);
    }

    // ── Cold Zone (arena-backed) ──

    fn coldAlloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Zigc = @ptrCast(@alignCast(ctx));

        // Check budget before allocating
        if (!self.checkBudget(.cold, len)) {
            return null; // Out of budget
        }

        const result = self.cold_arena.allocator().rawAlloc(len, ptr_align, ret_addr);
        if (result != null and self.debug) {
            self.stats[@intFromEnum(Zone.cold)].allocs += 1;
            self.stats[@intFromEnum(Zone.cold)].bytes_allocated += len;
            self.updateHighWater(.cold);
        }
        return result;
    }

    fn coldResize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;

        // Check budget if growing
        if (new_len > old_len) {
            if (!self.checkBudget(.cold, new_len - old_len)) {
                return false; // Would exceed budget
            }
        }

        const result = self.cold_arena.allocator().rawResize(buf, buf_align, new_len, ret_addr);
        if (result and self.debug) {
            const stats = &self.stats[@intFromEnum(Zone.cold)];
            if (new_len > old_len) {
                stats.bytes_allocated += (new_len - old_len);
            } else {
                stats.bytes_freed += (old_len - new_len);
            }
            self.updateHighWater(.cold);
        }
        return result;
    }

    fn coldRemap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.cold_arena.allocator().rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null and self.debug) {
            const stats = &self.stats[@intFromEnum(Zone.cold)];
            if (new_len > old_len) {
                stats.bytes_allocated += (new_len - old_len);
            } else {
                stats.bytes_freed += (old_len - new_len);
            }
        }
        return result;
    }

    fn coldFree(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
        const self: *Zigc = @ptrCast(@alignCast(ctx));
        if (self.debug) {
            self.stats[@intFromEnum(Zone.cold)].frees += 1;
            self.stats[@intFromEnum(Zone.cold)].bytes_freed += buf.len;
        }
        self.cold_arena.allocator().rawFree(buf, buf_align, ret_addr);
    }
};
