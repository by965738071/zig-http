const std = @import("std");
const Metrics = @import("monitoring.zig").Metrics;

/// Prometheus metrics exporter
pub const PrometheusExporter = struct {
    metrics: *Metrics,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, metrics: *Metrics) PrometheusExporter {
        return .{
            .metrics = metrics,
            .allocator = allocator,
        };
    }

    /// Export metrics in Prometheus text format
    pub fn export(exporter: *PrometheusExporter) ![]const u8 {
        var buffer = std.ArrayList(u8).init(exporter.allocator);

        // Export HTTP requests counter
        try exporter.appendHelp(&buffer, "http_requests_total", "Total HTTP requests");
        try exporter.appendCounter(&buffer, "http_requests_total", exporter.metrics.request_count);

        // Export HTTP errors counter
        try exporter.appendHelp(&buffer, "http_errors_total", "Total HTTP errors");
        try exporter.appendCounter(&buffer, "http_errors_total", exporter.metrics.error_count);

        // Export latency metrics
        try exporter.appendHelp(&buffer, "http_latency_seconds", "HTTP request latency in seconds");
        try exporter.appendLatencyMetrics(&buffer);

        // Export status codes
        try exporter.appendHelp(&buffer, "http_response_status", "HTTP response status code distribution");
        try exporter.appendStatusCodeMetrics(&buffer);

        // Export active connections
        try exporter.appendHelp(&buffer, "http_active_connections", "Current number of active connections");
        try exporter.appendGauge(&buffer, "http_active_connections", exporter.metrics.active_connections);

        // Export bytes sent/received
        try exporter.appendHelp(&buffer, "http_bytes_sent_total", "Total bytes sent");
        try exporter.appendCounter(&buffer, "http_bytes_sent_total", exporter.metrics.bytes_sent);

        try exporter.appendHelp(&buffer, "http_bytes_received_total", "Total bytes received");
        try exporter.appendCounter(&buffer, "http_bytes_received_total", exporter.metrics.bytes_received);

        return buffer.toOwnedSlice();
    }

    fn appendHelp(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8), name: []const u8, help: []const u8) !void {
        try buffer.writer().print("# HELP {s} {s}\n", .{ name, help });
        try buffer.writer().print("# TYPE {s} gauge\n", .{name});
    }

    fn appendCounter(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8), name: []const u8, value: u64) !void {
        _ = exporter;
        try buffer.writer().print("{s} {d}\n", .{ name, value });
    }

    fn appendGauge(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8), name: []const u8, value: usize) !void {
        _ = exporter;
        try buffer.writer().print("{s} {d}\n", .{ name, value });
    }

    fn appendLatencyMetrics(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8)) !void {
        const latency_sum = exporter.metrics.total_latency_ns;
        const latency_count = exporter.metrics.request_count;
        const avg_latency = if (latency_count > 0)
            @as(f64, @floatFromInt(latency_sum)) / @as(f64, @floatFromInt(latency_count))
        else
            0.0;

        // Sum
        const latency_sum_sec = @as(f64, @floatFromInt(latency_sum)) / 1e9;
        try buffer.writer().print("http_latency_seconds_sum {d:.6}\n", .{latency_sum_sec});

        // Count
        try buffer.writer().print("http_latency_seconds_count {d}\n", .{latency_count});

        // Average
        try buffer.writer().print("http_latency_seconds_avg {d:.6}\n", .{avg_latency});
    }

    fn appendStatusCodeMetrics(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8)) !void {
        // Export status code distribution
        // Note: This requires Metrics to track status codes separately
        // For now, export a placeholder
        try buffer.writer().print("http_response_status{{code=\"2xx\"}} 0\n", .{});
        try buffer.writer().print("http_response_status{{code=\"3xx\"}} 0\n", .{});
        try buffer.writer().print("http_response_status{{code=\"4xx\"}} 0\n", .{});
        try buffer.writer().print("http_response_status{{code=\"5xx\"}} 0\n", .{});
    }
};

/// Middleware handler for /metrics endpoint
pub const MetricsHandler = struct {
    exporter: *PrometheusExporter,

    pub fn init(exporter: *PrometheusExporter) MetricsHandler {
        return .{ .exporter = exporter };
    }

    /// Serve metrics in Prometheus format
    pub fn serve(handler: *MetricsHandler, ctx: anytype) !void {
        const metrics_data = try handler.exporter.export();
        defer handler.exporter.allocator.free(metrics_data);

        try ctx.setHeader("Content-Type", "text/plain; version=0.0.4");
        try ctx.write(metrics_data);
    }
};
