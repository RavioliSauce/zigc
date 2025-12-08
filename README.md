# zigc

> **GC for Zig. (Not really, it's just arenas.)**  
> A region-based memory manager with three zones (hot/warm/cold) for simple, deterministic, and fast memory management.

[![Zig Version](https://img.shields.io/badge/zig-0.15.0+-orange.svg)](https://ziglang.org/download/)

---

## What is this?

**zigc** is a small library that gives you **GC-like ergonomics** without a real garbage collector. It's **region-based memory management** with three distinct zones that map to how you naturally think about object lifetimes:

- 🔥 **Hot**: Ultra-short-lived allocations with explicit free (pass-through to backing allocator)
- 🌡️ **Warm**: Per-request/per-frame/per-job arenas, freed in bulk with `reset()`
- ❄️ **Cold**: Long-lived arenas for caches and config, freed on shutdown

**The result:**  
Write mostly "just allocate and go" code, but keep **deterministic lifetimes, no background GC, and no hidden pauses**.

---

## Quick Start

```zig
const std = @import("std");
const Zigc = @import("zigc").Zigc;

pub fn main() !void {
    // Initialize with any backing allocator
    var zigc = Zigc.init(std.heap.page_allocator, .{});
    defer zigc.deinit();

    // Hot zone: manual lifetime management
    const hot = zigc.allocator(.hot);
    const scratch = try hot.alloc(u8, 256);
    defer hot.free(scratch);

    // Warm zone: per-request/per-frame arena
    const warm = zigc.allocator(.warm);
    defer warm.reset(); // Free everything at once
    
    const request_data = try warm.alloc(u8, 1024);
    const response = try std.fmt.allocPrint(warm.asAllocator(), "Hello {}!", .{"World"});
    // No individual frees needed!

    // Cold zone: long-lived data
    const cold = zigc.allocator(.cold);
    const cache = try cold.alloc(u8, 4096);
    // Freed automatically on zigc.deinit()
}
```

---

## Features

- ✅ **Three-zone model** – hot/warm/cold zones for different lifetime patterns
- ✅ **Drop-in allocator** – exposes standard `std.mem.Allocator` interface
- ✅ **Scoped lifetimes** – design around frames, requests, jobs instead of per-object frees
- ✅ **Debug mode** – allocation tracking, leak detection with `ZoneGuard`
- ✅ **Fast arenas** – warm/cold zones use `std.heap.ArenaAllocator` backed by your chosen allocator
- ✅ **Zero magic** – no tracing GC, no threads, no hidden global state
- ✅ **Memory control** – `reset(.retain_capacity)` or `reset(.release)` modes
- ✅ **Memory budgets** – prevent unbounded growth with per-zone limits
- ✅ **High-water marks** – track peak usage for capacity planning

---

## New: Memory Budgets & Metrics

Prevent unbounded growth and tune your memory usage with built-in budgets and metrics.

### Memory Budgets

Set per-zone limits to prevent runaway allocations:

```zig
var zigc = Zigc.init(allocator, .{
    .warm_limit = 64 * 1024 * 1024,  // 64MB cap
    .cold_limit = 256 * 1024 * 1024, // 256MB cap
});

// Allocations that would exceed the limit return error.OutOfMemory
const data = warm.alloc(u8, too_much);  // Fails if over budget
```

**Use cases:**
- Prevent OOM in request handlers
- Cap cache sizes
- Enforce memory SLAs
- Embedded systems with hard limits

### High-Water Mark Tracking

Track peak memory usage to right-size your budgets:

```zig
// Run without budget first
var zigc = Zigc.init(allocator, .{ .debug = true });
defer zigc.deinit();

// ... process workload ...

// Check peak usage
const m = zigc.metrics(.warm);
std.debug.print("Peak: {}KB\n", .{m.high_water_bytes / 1024});

// Set budget = peak * 1.2 (with headroom)
const recommended_limit = m.high_water_bytes * 12 / 10;
```

### Enhanced Metrics

Get comprehensive insights beyond basic stats:

```zig
const m = zigc.metrics(.warm);

m.current_bytes      // Current allocated bytes
m.high_water_bytes   // Peak bytes since init
m.total_allocs       // Total allocations made
m.total_frees        // Total frees called
m.reset_count        // Number of resets
m.current_allocs     // Current allocation count
```

**Tuning workflow:**
1. Run workload without budgets, collect `high_water_bytes`
2. Set `warm_limit = high_water_bytes * 1.2` (20% headroom)
3. Monitor in production, adjust if needed
4. Use `reset_count` to tune reset frequency

---

## The Three Zones Explained

### 🔥 Hot Zone
**Use for:** Tiny, ephemeral allocations with well-defined lifetimes

```zig
const hot = zigc.allocator(.hot);
const buf = try hot.alloc(u8, 128);
defer hot.free(buf); // Must free manually

// Good for: scratch buffers, temporary formatting, leaf function locals
```

- Direct pass-through to backing allocator
- You must call `free()` for each allocation
- Use `ZoneGuard` to detect leaks in debug builds

### 🌡️ Warm Zone
**Use for:** Request/frame/job scoped data

```zig
fn handleRequest(zigc: *Zigc, request: Request) !Response {
    const warm = zigc.allocator(.warm);
    defer warm.reset(); // Everything freed here
    
    const parsed = try parseRequest(warm.asAllocator(), request);
    const result = try processData(warm.asAllocator(), parsed);
    return try buildResponse(warm.asAllocator(), result);
}
```

- Arena-based bulk freeing
- No individual frees needed
- Perfect for request handlers, frame loops, job workers

### ❄️ Cold Zone
**Use for:** Long-lived caches, config, global state

```zig
var zigc = Zigc.init(allocator, .{});
defer zigc.deinit();

const cold = zigc.allocator(.cold);
const cache = try cold.create(Cache);
cache.* = try Cache.init(cold.asAllocator());

// Lives until zigc.deinit()
```

- Arena-based, survives warm resets
- Freed on `cold.deinit()` or `zigc.deinit()`
- Can be reset independently with `cold.reset()`

---

## API Reference

### Initialization

```zig
// Default config (debug mode in debug/safe builds)
var zigc = Zigc.init(backing_allocator, .{});

// Explicit config
var zigc = Zigc.init(backing_allocator, .{
    .debug = true, // Enable stats tracking and leak detection
});

defer zigc.deinit(); // Frees all zones
```

### Getting Zone Allocators

```zig
const hot = zigc.allocator(.hot);   // Pass-through allocator
const warm = zigc.allocator(.warm); // Arena allocator
const cold = zigc.allocator(.cold); // Arena allocator

// Use as standard Zig allocator
const alloc = warm.asAllocator();
var list = std.ArrayList(u8).init(alloc); // or 
```

### Resetting Zones

```zig
// Retain capacity (fast, keeps memory allocated)
warm.reset();
// or explicitly:
warm.reset(.retain_capacity);

// Release memory back to backing allocator
warm.reset(.release);

// Hot zone reset is a no-op (use ZoneGuard to verify balance)
hot.reset();
```

### Debug Features

Debug mode is **automatically enabled** when using `zig build` (defaults to Debug mode) or `zig build -Doptimize=ReleaseSafe`. It's **disabled** in `-Doptimize=ReleaseFast` and `-Doptimize=ReleaseSmall`.

You can also explicitly control it:

```zig
// Explicitly enable (default in Debug/ReleaseSafe builds)
var zigc = Zigc.init(allocator, .{ .debug = true });

// Explicitly disable for zero overhead (default in ReleaseFast/ReleaseSmall)
var zigc = Zigc.init(allocator, .{ .debug = false });

// Get allocation statistics (only meaningful when debug = true)
const stats = zigc.snapshot(.warm);
std.debug.print("Allocs: {}, Bytes: {}\n", .{
    stats.allocs,
    stats.bytes_allocated,
});

// RAII leak detection
{
    var guard = zigc.zoneGuard(.hot);
    defer guard.deinit(); // Panics if allocations leaked
    
    const buf = try hot.alloc(u8, 64);
    hot.free(buf); // guard.deinit() will pass
}

// Manual leak checking
var guard = zigc.zoneGuard(.hot);
// ... allocations ...
if (guard.checkLeak()) |leak| {
    std.debug.print("Leaked: {} allocs, {} bytes\n", .{
        leak.allocs_leaked,
        leak.bytes_leaked,
    });
}
```

---

## Use Cases

### ✅ Perfect For

- **Web servers** – one warm arena per request
- **Game engines** – per-frame warm arena, cold for assets/caches
- **Job queues** – each job gets its own warm scope
- **Compilers/parsers** – per-compilation-unit/per-phase arenas
- **Batch processors** – per-item warm arena
- **Prototyping** – "just allocate" without sprinkling frees

### ❌ Not Ideal For

- Long-lived objects with independent, unpredictable lifetimes
- Fine-grained memory reclamation (freeing individual items mid-scope)
- Code that needs to free in arbitrary order
- Workloads where a real GC would be better (consider another language)

---

## Real-World Example: HTTP Server

```zig
const Server = struct {
    zigc: Zigc,
    
    pub fn init(backing: Allocator) !Server {
        return .{
            .zigc = Zigc.init(backing, .{ .debug = false }),
        };
    }
    
    pub fn deinit(self: *Server) void {
        self.zigc.deinit();
    }
    
    pub fn handleRequest(self: *Server, req: *Request) !Response {
        const warm = self.zigc.allocator(.warm);
        defer warm.reset(); // Everything freed here
        
        // Parse headers (allocates)
        const headers = try parseHeaders(warm.asAllocator(), req.raw_headers);
        
        // Route and process (allocates freely)
        const route = try self.router.match(warm.asAllocator(), req.path);
        const data = try route.handler(warm.asAllocator(), headers, req.body);
        
        // Build response (allocates)
        const json = try std.json.stringify(data, .{}, warm.asAllocator());
        
        return Response{
            .status = 200,
            .body = json, // Caller copies before warm.reset()
        };
        
        // warm.reset() runs here - all request memory freed at once!
    }
};
```

---

## Performance

From benchmarks (10,000 allocations × 64 bytes):

| Mode | Time | vs Std Arena | Notes |
|------|------|--------------|-------|
| `debug: true` | 5.3ms | +48% overhead | Includes stats, high-water marks |
| `debug: false` | ~3.6ms | ~0% overhead | Zero cost abstraction |
| Budget check | <1% | Negligible | Single comparison per alloc |
| High-water update | <1% | Negligible | Single comparison per alloc |

**Takeaway:** Negligible overhead in release builds. Debug features and budgets add minimal cost. The metrics are worth it for production tuning.

---

## Installation

### Using Zig Package Manager

**build.zig.zon:**
```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zigc = .{
            .url = "https://github.com/RavioliSauce/zigc/archive/refs/heads/main.tar.gz",
            // Replace with actual hash after first fetch
        },
    },
}
```

**build.zig:**
```zig
const zigc = b.dependency("zigc", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zigc", zigc.module("zigc"));
```

### Manual Installation

1. Copy `zigc.zig` to your project
2. Import: `const Zigc = @import("zigc.zig").Zigc;`

---

## Philosophy: The "Generational" Mental Model

I think of memory in three temperature zones:

- **Hot**: Blazing fast, dies immediately (explicit free)
- **Warm**: Moderate lifetime, dies at scope boundaries (arena)
- **Cold**: Long-lived, dies at major lifecycle events (arena)

**Default strategy:** Use warm/cold zones for 95% of allocations. Reserve hot zone for proven bottlenecks where you need tight control.

This gives you:
- **Simplicity**: Most code just allocates and forgets
- **Performance**: Arena bulk-free is nearly free
- **Clarity**: Explicit scope boundaries make lifetimes obvious
- **Flexibility**: Hot zone escape hatch when needed

---

## Design Decisions

### Why Three Zones?

**Two zones (hot/cold) is too coarse:**
- Forces you to choose between "manual free" and "never free until shutdown"
- No good place for request/frame scoped data

**Three zones hit the sweet spot:**
- Hot: explicit control when needed
- Warm: the workhorse for scoped lifetimes
- Cold: long-lived state

### Why Not Just Use ArenaAllocator Directly?

You can! But Zigc adds:
- Standardized naming (hot/warm/cold) for mental model
- Debug tracking and leak detection
- Multiple arenas in one handle
- Ergonomic `ZoneAllocator` wrapper
- Force you to think about lifetimes upfront

### Why "Not Really GC"?

Because there's no automatic garbage collection! You explicitly:
- Call `free()` in hot zone
- Call `reset()` for warm/cold zones
- Manage scope boundaries yourself

It's **region-based memory management**, not garbage collection.

---

## Testing

```bash
# Run library tests
zig build test
```

---

## FAQ

**Q: Can I nest warm zone scopes?**  
A: No, there's one warm arena per `Zigc` instance. Create multiple `Zigc` instances if you need nested scopes, or use a separate `ArenaAllocator`.

**Q: What happens if I use pointers after `reset()`?**  
A: Undefined behavior, just like any use-after-free. Zigc can't prevent this - it's your responsibility to respect scope boundaries.

**Q: Can I mix Zigc with other allocators?**  
A: Absolutely! Use Zigc for the 80% case, and specialized allocators for the 20%.

**Q: Is this thread-safe?**  
A: No. Each thread should have its own `Zigc` instance, or protect shared instances with mutexes.

**Q: Does `.release` mode actually free memory to the OS?**  
A: It frees to the backing allocator. Whether that goes to the OS depends on your backing allocator (e.g., `PageAllocator` releases to OS, `SmpAllocator` retains in cache).

---

## Contributing

This is a personal project, but suggestions and PRs are welcome! Please:
- Keep the API minimal and focused
- Add tests for new features
- Follow existing code style

---

## License

MIT

---

## Credits

Built with Zig's excellent arena allocator primitives. The three-zone concept was inspired by generational GC but adapted for explicit, deterministic memory management.
