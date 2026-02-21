const std = @import("std");
const Middleware = @import("../middleware.zig").Middleware;
const Context = @import("../context.zig").Context;
const Io = std.Io;

/// Distributed tracing middleware configuration
pub const TracingConfig = struct {
    enable_distributed: bool = true,
    trace_id_header: []const u8 = "X-Trace-ID",
    parent_span_id_header: []const u8 = "X-Parent-Span-ID",
};

/// Trace context for distributed tracing
pub const TraceContext = struct {
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8,
    started_at_ns: i64,
};

/// Distributed tracing middleware (OpenTelemetry compatible)
pub const TracingMiddleware = struct {
    config: TracingConfig,

    pub fn init(config: TracingConfig) TracingMiddleware {
        return .{ .config = config };
    }

    pub fn process(self: *TracingMiddleware, ctx: *Context, io: std.Io) !Middleware.NextAction {
        // Generate or extract trace ID
        const trace_id = self.getOrCreateTraceId(ctx);
        const span_id = self.generateSpanId(ctx.allocator);
        defer ctx.allocator.free(span_id);

        // Extract parent span ID if present
        const parent_span_id = if (self.config.enable_distributed)
            self.getParentSpanId(ctx)
        else
            null;

        // Create trace context
        const trace_context = TraceContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = parent_span_id,
            .started_at_ns = std.time.nanoTimestamp(),
        };

        // Store trace context for use in handlers
        try ctx.setState("trace_context", try self.serializeTraceContext(ctx.allocator, &trace_context));

        // Set response headers for distributed tracing
        try ctx.setHeader("X-Trace-ID", trace_id);
        try ctx.setHeader("X-Span-ID", span_id);

        std.log.debug("Trace: {s} Span: {s}", .{ trace_id, span_id });

        return .@"continue";
    }

    fn getOrCreateTraceId(self: *TracingMiddleware, ctx: *Context) []const u8 {
        // Check if trace ID is in headers
        if (self.config.enable_distributed) {
            const existing_trace_id = ctx.getHeader(self.config.trace_id_header);
            if (existing_trace_id != null) {
                return existing_trace_id.?;
            }
        }

        // Generate new trace ID
        return ctx.getRequestId(); // Use request ID as trace ID
    }

    fn getParentSpanId(self: *TracingMiddleware, ctx: *Context) ?[]const u8 {
        if (!self.config.enable_distributed) return null;

        const parent_span_id = ctx.getHeader(self.config.parent_span_id_header);
        return parent_span_id;
    }

    fn generateSpanId(self: *TracingMiddleware, allocator: std.mem.Allocator) ![]const u8 {
        const utils = @import("../utils.zig");
        return utils.generateShortId(allocator);
    }

    fn serializeTraceContext(self: *TracingMiddleware, allocator: std.mem.Allocator, trace: *const TraceContext) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        try buffer.writer().print(
            "trace_id={s},span_id={s},started_at={d}",
            .{ trace.trace_id, trace.span_id, trace.started_at_ns },
        );
        return buffer.toOwnedSlice();
    }
};
