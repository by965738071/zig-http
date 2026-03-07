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
    pub fn toPrometheus(exporter: *PrometheusExporter) ![]const u8 {
        var buffer = std.ArrayList(u8){};

        // Export HTTP requests counter
        try exporter.appendHelp(&buffer, "http_requests_total", "Total HTTP requests");
        try exporter.appendCounter(&buffer, "http_requests_total", exporter.metrics.total_requests);

        // Export HTTP errors counter
        try exporter.appendHelp(&buffer, "http_errors_total", "Total HTTP errors");
        try exporter.appendCounter(&buffer, "http_errors_total", exporter.metrics.total_errors);

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
        try exporter.appendCounter(&buffer, "http_bytes_sent_total", 0);

        try exporter.appendHelp(&buffer, "http_bytes_received_total", "Total bytes received");
        try exporter.appendCounter(&buffer, "http_bytes_received_total", 0);

        return buffer.toOwnedSlice(exporter.allocator);
    }

    fn appendHelp(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8), name: []const u8, help: []const u8) !void {
        try buffer.print(exporter.allocator, "# HELP {s} {s}\n", .{ name, help });
        try buffer.print(exporter.allocator, "# TYPE {s} gauge\n", .{name});
    }

    fn appendCounter(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8), name: []const u8, value: u64) !void {
        try buffer.print(exporter.allocator, "{s} {d}\n", .{ name, value });
    }

    fn appendGauge(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8), name: []const u8, value: usize) !void {
        try buffer.print(exporter.allocator, "{s} {d}\n", .{ name, value });
    }

    fn appendLatencyMetrics(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8)) !void {
        const latency_count = exporter.metrics.total_requests;
        const avg_latency = exporter.metrics.avg_response_time_ms;

        const latency_sum_sec = avg_latency / 1000.0;
        try buffer.print(exporter.allocator, "http_latency_seconds_sum {d:.6}\n", .{latency_sum_sec});
        try buffer.print(exporter.allocator, "http_latency_seconds_count {d}\n", .{latency_count});
        try buffer.print(exporter.allocator, "http_latency_seconds_avg {d:.6}\n", .{avg_latency / 1000.0});
    }

    fn appendStatusCodeMetrics(exporter: *PrometheusExporter, buffer: *std.ArrayList(u8)) !void {
        try buffer.print(exporter.allocator, "http_response_status{{code=\"2xx\"}} 0\n", .{});
        try buffer.print(exporter.allocator, "http_response_status{{code=\"3xx\"}} 0\n", .{});
        try buffer.print(exporter.allocator, "http_response_status{{code=\"4xx\"}} 0\n", .{});
        try buffer.print(exporter.allocator, "http_response_status{{code=\"5xx\"}} 0\n", .{});
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
        const metrics_data = try handler.exporter.toPrometheus();
        defer handler.exporter.allocator.free(metrics_data);

        try ctx.setHeader("Content-Type", "text/plain; version=0.0.4");
        try ctx.write(metrics_data);
    }
};
