const std = @import("std");
const Io = std.Io;

/// Signal types to handle
pub const Signal = enum {
    interrupt,  // SIGINT (Ctrl+C)
    terminate,  // SIGTERM
    quit,       // SIGQUIT (Ctrl+\)
};

/// Signal handler configuration
pub const SignalHandlerConfig = struct {
    handle_interrupt: bool = true,
    handle_terminate: bool = true,
    handle_quit: bool = false,
};

/// Signal handler for graceful shutdown
pub const SignalHandler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    shutdown_requested: std.atomic.Value(bool),
    config: SignalHandlerConfig,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: SignalHandlerConfig) !SignalHandler {
        const handler = SignalHandler{
            .allocator = allocator,
            .io = io,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .config = config,
        };

        std.log.info("Signal handler initialized", .{});

        return handler;
    }

    pub fn deinit(self: *SignalHandler) void {
        _ = self;
    }

    /// Check if shutdown has been requested
    pub fn isShutdownRequested(self: *const SignalHandler) bool {
        return self.shutdown_requested.load(.acquire);
    }

    /// Request shutdown programmatically
    pub fn requestShutdown(self: *SignalHandler) void {
        self.shutdown_requested.store(true, .release);
        std.log.info("Shutdown requested", .{});
    }

    /// Set up signal handling thread
    /// Note: Full POSIX signal handling requires platform-specific APIs
    /// that vary between Zig versions. For production use, implement:
    /// - sigaction for signal handler registration
    /// - pthread_sigmask for signal blocking
    /// - sigwait for synchronous signal waiting
    pub fn setupSignalThread(self: *SignalHandler) !void {
        _ = self;
        std.log.info("Signal handling thread: Platform-specific implementation pending", .{});

        // TODO: Implement platform-specific signal handling
        // For Linux: use signalfd or sigwaitinfo
        // For macOS: use kqueue for signal notifications
        // The server can be gracefully shut down programmatically
        // via requestShutdown() or by checking isShutdownRequested()
    }
};

/// Helper function to integrate signal handling into server loop
/// Call this periodically in your accept loop
pub fn checkSignal(handler: *SignalHandler) bool {
    return handler.isShutdownRequested();
}
