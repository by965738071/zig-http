const std = @import("std");

/// Benchmark result
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    avg_time_ms: i64,
};

/// Simple benchmark function
pub fn benchmark(name: []const u8, iterations: usize, fn_ptr: *const fn () anyerror!void) !BenchmarkResult {
    var total_time: i64 = 0;
    var i: usize = 0;
    while (i < iterations) {
        const start = std.time.milliTimestamp();
        fn_ptr() catch |err| {
            std.log.err("Benchmark '{s}' failed on iteration {d}: {}", .{ name, i, err });
            return err;
        };
        const end = std.time.milliTimestamp();
        total_time += (end - start);
        i += 1;
    }

    const avg_time = if (iterations > 0) total_time / @as(i64, @intCast(iterations)) else 0;

    std.log.info("{s}: {d} iterations, avg={d}ms", .{ name, iterations, avg_time });

    return BenchmarkResult{
        .name = name,
        .iterations = iterations,
        .avg_time_ms = avg_time,
    };
}
