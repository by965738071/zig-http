const std = @import("std");

/// Upload progress callback function signature
pub const ProgressCallback = *const fn (progress: *Progress) void;

/// Upload progress information
pub const Progress = struct {
    /// Unique upload identifier
    upload_id: []const u8,
    /// Total bytes to upload (0 if unknown)
    total_bytes: usize,
    /// Bytes uploaded so far
    uploaded_bytes: usize,
    /// Upload percentage (0-100)
    percentage: f64,
    /// Bytes per second
    speed_bps: f64,
    /// Estimated remaining time in seconds
    eta_seconds: f64,
    /// Upload start timestamp (ms)
    start_time: i64,
    /// Current timestamp (ms)
    current_time: i64,
    /// Is upload complete
    complete: bool,
    /// Error if upload failed
    error_val: ?anyerror = null,

    /// Calculate upload percentage
    pub fn calculatePercentage(progress: *Progress) f64 {
        if (progress.total_bytes == 0) return 0;
        return @as(f64, @floatFromInt(progress.uploaded_bytes)) / @as(f64, @floatFromInt(progress.total_bytes)) * 100.0;
    }

    /// Calculate upload speed
    pub fn calculateSpeed(progress: *Progress) f64 {
        const elapsed_ms = progress.current_time - progress.start_time;
        if (elapsed_ms <= 0) return 0;
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        if (elapsed_seconds == 0) return 0;
        return @as(f64, @floatFromInt(progress.uploaded_bytes)) / elapsed_seconds;
    }

    /// Calculate estimated time remaining
    pub fn calculateETA(progress: *Progress) f64 {
        const speed = progress.calculateSpeed();
        if (speed == 0) return 0;
        const remaining_bytes = if (progress.total_bytes > progress.uploaded_bytes)
            progress.total_bytes - progress.uploaded_bytes
        else
            0;
        return @as(f64, @floatFromInt(remaining_bytes)) / speed;
    }

    /// Update progress
    pub fn update(progress: *Progress, uploaded_bytes: usize, current_time: i64) void {
        progress.uploaded_bytes = uploaded_bytes;
        progress.current_time = current_time;
        progress.percentage = progress.calculatePercentage();
        progress.speed_bps = progress.calculateSpeed();
        progress.eta_seconds = progress.calculateETA();

        if (progress.total_bytes > 0 and progress.uploaded_bytes >= progress.total_bytes) {
            progress.complete = true;
        }
    }

    /// Format progress for logging
    pub fn format(progress: *Progress, allocator: std.mem.Allocator) ![]u8 {
        const complete_str = if (progress.complete) "[COMPLETE]" else "[UPLOADING]";
        return std.fmt.allocPrint(allocator, "{s} {s}: {d:.2}% ({d}/{d} bytes) @ {d:.2} KB/s ETA: {d:.1}s",
            .{
                complete_str,
                progress.upload_id,
                progress.percentage,
                progress.uploaded_bytes,
                progress.total_bytes,
                progress.speed_bps / 1024.0,
                progress.eta_seconds,
            });
    }
};

/// Upload tracker - manages multiple concurrent uploads
pub const UploadTracker = struct {
    allocator: std.mem.Allocator,
    uploads: std.StringHashMap(*Progress),
    counter: std.atomic.Value(u64),
    default_callback: ?ProgressCallback,

    pub fn init(allocator: std.mem.Allocator) UploadTracker {
        return .{
            .allocator = allocator,
            .uploads = std.StringHashMap(*Progress).init(allocator),
            .counter = std.atomic.Value(u64).init(0),
            .default_callback = null,
        };
    }

    pub fn deinit(self: *UploadTracker) void {
        var iter = self.uploads.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.uploads.deinit();
    }

    /// Set default progress callback
    pub fn setDefaultCallback(self: *UploadTracker, callback: ProgressCallback) void {
        self.default_callback = callback;
    }

    /// Start tracking a new upload
    pub fn startUpload(self: *UploadTracker, total_bytes: usize) !*Progress {
        const upload_id = try self.generateUploadId();
        const now = std.time.milliTimestamp();

        const progress = try self.allocator.create(Progress);
        progress.* = Progress{
            .upload_id = upload_id,
            .total_bytes = total_bytes,
            .uploaded_bytes = 0,
            .percentage = 0,
            .speed_bps = 0,
            .eta_seconds = 0,
            .start_time = now,
            .current_time = now,
            .complete = false,
            .error_val = null,
        };

        try self.uploads.put(upload_id, progress);
        return progress;
    }

    /// Update upload progress
    pub fn updateProgress(self: *UploadTracker, upload_id: []const u8, uploaded_bytes: usize) !void {
        const progress = self.uploads.get(upload_id) orelse return error.UploadNotFound;
        const now = std.time.milliTimestamp();
        progress.update(uploaded_bytes, now);

        // Call callback if set
        if (self.default_callback) |callback| {
            callback(progress);
        }
    }

    /// Mark upload as complete
    pub fn completeUpload(self: *UploadTracker, upload_id: []const u8) !void {
        const progress = self.uploads.get(upload_id) orelse return error.UploadNotFound;
        progress.complete = true;
        const now = std.time.milliTimestamp();
        progress.update(progress.total_bytes, now);

        if (self.default_callback) |callback| {
            callback(progress);
        }

        // Clean up after a short delay
        // In production, you might want to keep the progress info longer
        _ = self.uploads.remove(upload_id);
        self.allocator.free(upload_id);
        self.allocator.destroy(progress);
    }

    /// Mark upload as failed
    pub fn failUpload(self: *UploadTracker, upload_id: []const u8, err: anyerror) !void {
        const progress = self.uploads.get(upload_id) orelse return error.UploadNotFound;
        progress.error_val = err;
        const now = std.time.milliTimestamp();
        progress.update(progress.uploaded_bytes, now);

        if (self.default_callback) |callback| {
            callback(progress);
        }

        _ = self.uploads.remove(upload_id);
        self.allocator.free(upload_id);
        self.allocator.destroy(progress);
    }

    /// Get upload progress
    pub fn getProgress(self: *UploadTracker, upload_id: []const u8) ?*Progress {
        return self.uploads.get(upload_id);
    }

    /// Get all active uploads
    pub fn getActiveUploads(self: *UploadTracker) ![]const []const u8 {
        const count = self.uploads.count();
        const ids = try self.allocator.alloc([]const u8, count);

        var i: usize = 0;
        var iter = self.uploads.iterator();
        while (iter.next()) |entry| {
            ids[i] = entry.key_ptr.*;
            i += 1;
        }

        return ids;
    }

    /// Generate unique upload ID
    fn generateUploadId(self: *UploadTracker) ![]u8 {
        const counter = self.counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(self.allocator, "upload-{d:0>10}", .{counter});
    }
};

/// Built-in progress callbacks

/// Console progress callback - prints progress to console
pub fn consoleProgressCallback(progress: *Progress) void {
    const formatted = progress.format(std.heap.page_allocator) catch {
        std.log.err("Failed to format progress", .{});
        return;
    };
    defer std.heap.page_allocator.free(formatted);
    std.log.info("{s}", .{formatted});
}

/// JSON progress callback - returns progress as JSON
pub fn jsonProgressCallback(progress: *Progress) void {
    const json = std.json.stringifyAlloc(std.heap.page_allocator, .{
        .upload_id = progress.upload_id,
        .total_bytes = progress.total_bytes,
        .uploaded_bytes = progress.uploaded_bytes,
        .percentage = progress.percentage,
        .speed_bps = progress.speed_bps,
        .eta_seconds = progress.eta_seconds,
        .complete = progress.complete,
        .error_val = if (progress.error_val) |err| @errorName(err) else null,
    }, .{}) catch {
        std.log.err("Failed to serialize progress to JSON", .{});
        return;
    };
    defer std.heap.page_allocator.free(json);
    std.log.info("Progress: {s}", .{json});
}

/// Webhook progress callback - sends progress to webhook URL
pub fn webhookProgressCallback(url: []const u8) ProgressCallback {
    const Callback = struct {
        webhook_url: []const u8,

        fn callback(progress: *Progress) void {
            _ = progress;
            _ = @This().webhook_url;
            // TODO: Implement HTTP client to send progress to webhook
            // This would use the HTTP client module to send progress updates
            std.log.info("Webhook callback: {s}", .{url});
        }
    };

    const wrapper = std.heap.page_allocator.create(Callback) catch return undefined;
    wrapper.* = .{ .webhook_url = url };
    return &wrapper.callback;
}
