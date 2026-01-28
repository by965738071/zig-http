const std = @import("std");

/// 配置结构体，存储命令行参数
const Config = struct {
    target: []const u8,
    concurrency: usize,
    start_port: u16,
    end_port: u16,
    timeout: u64, // 超时时间（秒）
};

/// Worker 函数：扫描端口范围
fn scanPorts(
    io: std.Io,
    config: *const Config,
    local_results: *std.ArrayList(u16),
    start_port: u16,
    end_port: u16,
    allocator: std.mem.Allocator,
) void {
    var port = start_port;
    while (port <= end_port) {
        // 尝试连接端口
        const stream = std.Io.net.IpAddress.connect(std.Io.net.IpAddress.parseIp4(config.target, port) catch {
            port += 1;
            continue;
        }, io, .{ .mode = .stream }) catch {
            port += 1;
            continue;
        };
        stream.close(io);

        // 连接成功，添加到本地结果（无需加锁）
        local_results.append(allocator, port) catch |out_of_memory| {
            std.log.err("Out of memory while appending port {d}: {}", .{ port, out_of_memory });
        };
        port += 1;
    }
}

/// TCP 端口扫描（使用 std.Io.concurrent）
fn tcpScan(io: std.Io, allocator: std.mem.Allocator, config: *const Config) !void {
    // 为每个 worker 分配本地结果列表
    var worker_results = try std.ArrayList(std.ArrayList(u16)).initCapacity(allocator, config.concurrency);
    defer {
        for (worker_results.items) |*list| list.deinit(allocator);
        worker_results.deinit(allocator);
    }

    // 创建任务组
    var group: std.Io.Group = .init;

    // 创建任务
    const total_ports = config.end_port - config.start_port + 1;
    const ports_per_worker = total_ports / config.concurrency;
    const remaining_ports = total_ports % config.concurrency;

    std.log.info("Scanning {s}", .{config.target});

    var i: usize = 0;
    while (i < config.concurrency) : (i += 1) {
        const start = config.start_port + @as(u16, @intCast(i * ports_per_worker));
        var end = start + @as(u16, @intCast(ports_per_worker)) - 1;

        // 分配剩余端口
        if (i < remaining_ports) {
            end += 1;
        }

        // 超出范围则停止
        if (start > config.end_port) break;

        const actual_end = @min(end, config.end_port);

        // 为当前 worker 创建本地结果列表
        try worker_results.append(allocator, std.ArrayList(u16){});

        // 在组中启动并发任务（传入本地列表）
        _ = group.concurrent(io, scanPorts, .{
            io,
            config,
            &worker_results.items[i],
            start,
            actual_end,
            allocator,
        }) catch |err| {
            std.log.warn("Failed to start worker: {}", .{err});
        };
    }

    // 等待所有任务完成
    try group.await(io);

    // 汇总所有 worker 的结果
    var opened_ports = std.ArrayList(u16){};
    defer opened_ports.deinit(allocator);

    for (worker_results.items) |worker_list| {
        try opened_ports.appendSlice(allocator, worker_list.items);
    }

    // 排序结果
    std.sort.block(u16, opened_ports.items, {}, comptime std.sort.asc(u16));

    // 打印结果
    std.log.info("Open ports ({d} found):", .{opened_ports.items.len});
    for (opened_ports.items) |port| {
        std.log.info("  {d}", .{port});
    }
}

/// 等待用户按回车键
fn waitEnter(io: std.Io) !void {
    const stdin = std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    const reader = stdin.reader(&buf, io).interface;

    while (true) {
        const line = try reader.takeDelimiter('\n', 1024);

        if (line.len == 0) {
            break;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数

    var config = Config{
        .target = "127.0.0.1",
        .concurrency = 100,
        .start_port = 1,
        .end_port = 65535,
        .timeout = 1,
    };

    // 初始化 std.Io.Threaded
    var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = .limited(config.concurrency), .environ = .empty });
    defer threaded.deinit();

    const io = threaded.io();
    // 计时执行扫描
    const start = std.time.Instant.now() catch unreachable;
    try tcpScan(io, allocator, &config);
    const elapsed = std.time.Instant.now() catch unreachable;

    std.log.info("Execution Time: {}", .{elapsed.since(start)});

    // 等待用户按回车
    //try waitEnter(io);
}
