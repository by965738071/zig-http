const std = @import("std");

/// Benchmark result
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    avg_time_ms: i64,
};

/// Simple benchmark function
pub fn benchmark(name: []const u8, iterations: usize, fn_ptr: *const fn () anyerror!void, io: std.Io) !BenchmarkResult {
    var total_time: i96 = 0;
    var i: usize = 0;
    while (i < iterations) {
        const start = std.Io.Timestamp.now(io, .boot);
        fn_ptr() catch |err| {
            std.log.err("Benchmark '{s}' failed on iteration {d}: {}", .{ name, i, err });
            return err;
        };
        const end = std.Io.Timestamp.now(io, .boot);
        const elapsed_ns = end.toNanoseconds() - start.toNanoseconds();
        total_time += @divTrunc(elapsed_ns, 1_000_000); // Convert ns to ms
        i += 1;
    }

    const avg_time: i64 = if (iterations > 0) @intCast(@divTrunc(total_time, @as(i96, @intCast(iterations)))) else 0;

    std.log.info("{s}: {d} iterations, avg={d}ms", .{ name, iterations, avg_time });

    return BenchmarkResult{
        .name = name,
        .iterations = iterations,
        .avg_time_ms = avg_time,
    };
}
