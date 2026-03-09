/// Global state access for handlers
/// This module provides access to global state that handlers need

const StructuredLogger = @import("features/structured_log.zig").StructuredLogger;
const UploadTracker = @import("features/upload_progress.zig").UploadTracker;
const SessionManager = @import("features/session.zig").SessionManager;
const PrometheusExporter = @import("features/metrics_exporter.zig").PrometheusExporter;

// Global state references (set in main)
pub var g_structured_logger: ?*StructuredLogger = null;
pub var g_upload_tracker: ?*UploadTracker = null;
pub var g_session_manager: ?*SessionManager = null;
pub var g_prometheus_exporter: ?*PrometheusExporter = null;
