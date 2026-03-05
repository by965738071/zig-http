const std = @import("std");
const builtin = @import("builtin");
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

// Global signal handler pointer for Windows callback
var global_handler: ?*SignalHandler = null;

// Windows console control handler function
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (c_uint) callconv(.c) bool, add: c_int) bool;

// Windows signal callback
fn windowsSignalCallback(ctrl_type: c_uint) callconv(.c) bool {
    _ = ctrl_type;
    if (global_handler) |handler| {
        handler.requestShutdown();
    }
    return true;
}

/// Signal handler for graceful shutdown
pub const SignalHandler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    shutdown_requested: std.atomic.Value(bool),
    config: SignalHandlerConfig,
    signal_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: SignalHandlerConfig) !SignalHandler {
        const handler = SignalHandler{
            .allocator = allocator,
            .io = io,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .config = config,
            .signal_thread = null,
        };

        std.log.info("Signal handler initialized", .{});

        return handler;
    }

    pub fn deinit(self: *SignalHandler) void {
        if (self.signal_thread) |thread| {
            thread.join();
        }
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
    pub fn setupSignalThread(self: *SignalHandler) !void {
        if (comptime builtin.os.tag == .windows) {
            return self.setupWindowsSignalHandler();
        } else {
            return self.setupPosixSignalHandler();
        }
    }

    /// Windows signal handler using SetConsoleCtrlHandler
    fn setupWindowsSignalHandler(self: *SignalHandler) !void {
        global_handler = self;

        if (!SetConsoleCtrlHandler(&windowsSignalCallback, 1)) {
            return error.FailedToSetHandler;
        }

        std.log.info("Windows signal handler installed (Ctrl+C support)", .{});
    }

    /// POSIX signal handler using sigaction and sigwait
    fn setupPosixSignalHandler(self: *SignalHandler) !void {
        const posix = std.posix;

        // Block signals in main thread
        var sigset = posix.empty_sigset;
        if (self.config.handle_interrupt) {
            try posix.sigaddset(&sigset, posix.SIG.INT);
        }
        if (self.config.handle_terminate) {
            try posix.sigaddset(&sigset, posix.SIG.TERM);
        }
        if (self.config.handle_quit) {
            try posix.sigaddset(&sigset, posix.SIG.QUIT);
        }
        try posix.pthread_sigmask(posix.SIG.BLOCK, &sigset, null);

        // Start signal handling thread
        self.signal_thread = try std.Thread.spawn(.{}, signalHandlerThread, .{
            self,
            sigset,
        });

        std.log.info("POSIX signal handling thread started", .{});
    }

    fn signalHandlerThread(handler: *SignalHandler, sigset: std.posix.sigset_t) void {
        while (true) {
            var received_sig: c_int = 0;
            const rc = std.posix.sigwait(&sigset, &received_sig);

            if (rc == 0) {
                switch (received_sig) {
                    std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.QUIT => {
                        handler.requestShutdown();
                        break;
                    },
                    else => {},
                }
            }
        }
    }
};

/// Helper function to integrate signal handling into server loop
/// Call this periodically in your accept loop
pub fn checkSignal(handler: *SignalHandler) bool {
    return handler.isShutdownRequested();
}
