# Zig-HTTP 性能优化文档

## 概述

本文档描述了 zig-http 项目中实现的四个核心性能优化：
1. 零拷贝优化
2. 内存池实现
3. 连接复用优化
4. 缓冲区管理优化

这些优化旨在减少内存分配次数、降低 CPU 开销、提高 I/O 效率。

---

## 1. 零拷贝优化

### 概述

零拷贝技术通过避免数据在内存中的不必要复制，显著提升性能。

### 核心组件

#### BufferView

```zig
pub const BufferView = struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(slice: []const u8) BufferView
    pub fn slice(self: BufferView, start: usize, end: usize) BufferView
}
```

**用途**：
- 创建内存块的视图而不复制数据
- 支持切片操作（零拷贝）

**性能提升**：
- 避免不必要的内存分配
- 减少内存带宽使用
- 提高 CPU 缓存命中率

#### ZeroCopyBuilder

```zig
pub const ZeroCopyBuilder = struct {
    buffers: std.ArrayList(BufferView),
    total_len: usize,

    pub fn appendView(self: *Self, view: BufferView) !void
    pub fn appendSlice(self: *Self, slice: []const u8) !void
    pub fn build(self: *Self) ![]u8
    pub fn writeTo(self: *Self, writer: anytype) !void
}
```

**用途**：
- 构建响应而不立即复制数据
- 支持零拷贝写入

**性能提升**：
- 减少 memcpy 操作
- 延迟内存分配到必要时
- 支持流式写入

#### ZeroCopyResponse

```zig
pub const ZeroCopyResponse = struct {
    status_line: BufferView,
    headers: std.ArrayList(BufferView),
    body: std.ArrayList(BufferView),

    pub fn setStatusLine(self: *Self, line: []const u8) void
    pub fn addHeader(self: *Self, line: []const u8) !void
    pub fn writeTo(self: *Self, writer: anytype) !void
}
```

**用途**：
- 构建 HTTP 响应而不复制数据
- 支持直接写入网络

**性能提升**：
- 消除响应构建阶段的内存复制
- 减少内存碎片
- 提高网络写入效率

#### StringInterner

```zig
pub const StringInterner = struct {
    strings: std.StringHashMap([]const u8),

    pub fn intern(self: *Self, s: []const u8) ![]const u8
    pub fn get(self: Self, s: []const u8) ?[]const u8
}
```

**用途**：
- 存储字符串一次并重用指针
- 减少 HTTP 头部等重复字符串的内存占用

**性能提升**：
- 减少内存分配次数
- 降低内存使用量
- 提高字符串比较速度

#### ZeroCopyFileReader

```zig
pub const ZeroCopyFileReader = struct {
    file: std.fs.File,
    mapping: ?[]align(std.mem.page_size) u8,
    size: usize,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self
    pub fn content(self: *Self) ![]const u8
}
```

**用途**：
- 使用 mmap 读取文件（零拷贝）
- 支持大文件处理

**性能提升**：
- 避免文件内容的内存复制
- 减少内存使用
- 利用操作系统的页面缓存

#### SlicePool

```zig
pub const SlicePool = struct {
    buffers: std.ArrayList([]u8),
    buffer_size: usize,
    free_list: std.ArrayList(usize),

    pub fn acquire(self: *Self) ![]u8
    pub fn release(self: *Self, buffer: []u8) void
}
```

**用途**：
- 复用缓冲区切片
- 减少小块内存的分配/释放

**性能提升**：
- 减少内存分配器调用
- 降低内存碎片
- 提高内存局部性

---

## 2. 内存池实现

### 概述

内存池通过预分配和重用内存块，减少动态内存分配的开销。

### 核心组件

#### MemoryPool

```zig
pub const MemoryPool = struct {
    blocks: std.ArrayList([]u8),
    free_list: std.ArrayList(usize),
    config: PoolConfig,
    used_blocks: usize,

    pub fn alloc(self: *Self, size: usize) ![]u8
    pub fn free(self: *Self, ptr: []u8) void
    pub fn reset(self: *Self) void
}
```

**用途**：
- 管理固定大小的内存块
- 快速分配和释放
- 支持批量重置

**性能提升**：
- 分配时间：O(1)
- 无内存碎片
- 减少 malloc/free 调用

**配置选项**：
```zig
pub const PoolConfig = struct {
    block_size: usize = 4096,           // 每个块的大小
    max_blocks: usize = 1024,            // 最大块数
    small_size_threshold: usize = 256,   // 小对象优化阈值
};
```

#### RequestArena

```zig
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator) Self
    pub fn reset(self: *Self) void
    pub fn getUsage(self: Self) usize
}
```

**用途**：
- 请求作用域的内存分配
- 一次性释放所有分配
- 跟踪内存使用

**性能提升**：
- 批量释放（一次调用）
- 减少内存分配次数
- 简化内存管理

#### ObjectPool

```zig
pub fn ObjectPool(comptime T: type) type {
    return struct {
        objects: std.ArrayList(*T),
        max_objects: usize,

        pub fn acquire(self: *Self) !*T
        pub fn release(self: *Self, obj: *T) void
    };
}
```

**用途**：
- 重用对象实例
- 避免对象的重复构造
- 支持泛型类型

**性能提升**：
- 减少对象构造/析构开销
- 提高对象复用率
- 降低内存碎片

#### BufferPool

```zig
pub const BufferPool = struct {
    buffers: std.ArrayList([]u8),
    free_buffers: std.ArrayList([]u8),
    buffer_size: usize,
    max_buffers: usize,

    pub fn acquire(self: *Self) ![]u8
    pub fn release(self: *Self, buffer: []u8) void
}
```

**用途**：
- 管理网络缓冲区
- 重用相同大小的缓冲区
- 支持统计信息

**性能提升**：
- 减少缓冲区分配次数
- 提高缓冲区复用率
- 支持性能监控

#### StackAllocator

```zig
pub const StackAllocator = struct {
    base_ptr: [*]u8,
    current_ptr: [*]u8,
    end_ptr: [*]u8,

    pub fn init(buffer: []u8) Self
    pub fn alloc(self: *Self, size: usize, alignment: u29) ![]u8
    pub fn reset(self: *Self) void
    pub fn mark(self: Self) [*]u8
}
```

**用途**：
- 栈式内存分配
- 支持快速重置
- 适合临时数据

**性能提升**：
- 极快的分配速度
- 无内存碎片
- 支持 RAII 风格

---

## 3. 连接复用优化

### 概述

连接池通过重用 TCP 连接，减少连接建立的开销和延迟。

### 核心组件

#### ConnectionPool

```zig
pub const ConnectionPool = struct {
    config: PoolConfig,
    connections: std.StringHashMap(*PoolEntry),
    idle_connections: std.ArrayList(*PooledConnection),
    cleanup_task: ?std.Thread,

    pub fn acquire(self: *Self, host: []const u8, port: u16) !*PooledConnection
    pub fn release(self: *Self, conn: *PooledConnection) void
    pub fn cleanup(self: *Self) void
}
```

**用途**：
- 管理活跃和空闲连接
- 自动清理过期连接
- 支持连接复用

**性能提升**：
- 减少 TCP 握手延迟（~10-100ms）
- 降低系统调用次数
- 提高并发处理能力

**配置选项**：
```zig
pub const PoolConfig = struct {
    max_connections: usize = 100,
    max_idle_connections: usize = 10,
    max_idle_time: u64 = 60_000,        // 60 秒
    max_lifetime: u64 = 300_000,        // 5 分钟
    connection_timeout: u64 = 5_000,     // 5 秒
    cleanup_interval: u64 = 30_000,       // 30 秒
};
```

#### HttpConnectionPool

```zig
pub const HttpConnectionPool = struct {
    pool: ConnectionPool,
    allocator: std.mem.Allocator,

    pub fn request(
        self: *Self,
        method: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
        headers: []const []const u8,
        body: ?[]const u8,
    ) !HttpResponse
}
```

**用途**：
- HTTP 请求的高级接口
- 自动处理 Keep-Alive
- 支持连接复用

**性能提升**：
- 减少连接建立时间
- 提高请求吞吐量
- 降低服务器负载

#### 连接状态管理

```zig
pub const ConnState = enum {
    idle,
    in_use,
    closed,
};

pub const PooledConnection = struct {
    stream: std.net.Stream,
    host: []const u8,
    port: u16,
    state: ConnState,
    created_at: u64,
    last_used: u64,
    ref_count: Atomic(u32),
}
```

**特性**：
- 连接状态跟踪
- 引用计数
- 自动过期检测

---

## 4. 缓冲区管理优化

### 概述

缓冲区管理器提供高效的缓冲区分配、复用和管理机制。

### 核心组件

#### BufferManager

```zig
pub const BufferManager = struct {
    config: BufferConfig,
    free_read_buffers: std.ArrayList(*Buffer),
    used_read_buffers: std.ArrayList(*Buffer),
    free_write_buffers: std.ArrayList(*Buffer),
    used_write_buffers: std.ArrayList(*Buffer),

    pub fn acquireReadBuffer(self: *Self) ![]u8
    pub fn releaseReadBuffer(self: *Self, data: []u8) void
    pub fn getStats(self: *Self) BufferStats
}
```

**用途**：
- 管理读写缓冲区
- 支持缓冲区复用
- 提供性能统计

**性能提升**：
- 减少缓冲区分配次数
- 提高缓冲区复用率
- 支持性能监控

**配置选项**：
```zig
pub const BufferConfig = struct {
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 4096,
    max_read_buffers: usize = 100,
    max_write_buffers: usize = 100,
    enable_buffer_pooling: bool = true,
};
```

#### RingBuffer

```zig
pub fn RingBuffer(comptime T: type) type {
    return struct {
        data: []T,
        head: usize,
        tail: usize,
        capacity: usize,

        pub fn write(self: *Self, items: []const T) !usize
        pub fn read(self: *Self, buffer: []T) !usize
        pub fn availableWrite(self: Self) usize
        pub fn availableRead(self: Self) usize
    };
}
```

**用途**：
- 循环缓冲区实现
- 支持并发读写
- 无锁设计

**性能提升**：
- 避免 memcpy
- 减少内存分配
- 提高缓存效率

#### ZeroCopyBuffer

```zig
pub const ZeroCopyBuffer = struct {
    data: []u8,
    owner: ?*const ZeroCopyBuffer,

    pub fn fromSlice(slice: []const u8) ZeroCopyBuffer
    pub fn copy(slice: []const u8, allocator: std.mem.Allocator) !Self
    pub fn slice(self: *Self, start: usize, end: usize) !ZeroCopyBuffer
}
```

**用途**：
- 零拷贝缓冲区包装
- 支持所有权管理
- 自动内存释放

**性能提升**：
- 避免数据复制
- 简化内存管理
- 支持共享缓冲区

---

## 性能基准

### 预期性能提升

| 优化项 | 改进指标 | 说明 |
|--------|----------|------|
| 零拷贝 | 20-30% | 减少 memcpy 操作 |
| 内存池 | 15-25% | 减少内存分配开销 |
| 连接复用 | 30-50% | 减少连接建立延迟 |
| 缓冲区管理 | 10-20% | 减少内存碎片 |

### 综合性能

优化前：
- QPS: 7,500 - 10,000
- 平均延迟: ~1ms
- P99 延迟: <5ms

优化后（预期）：
- QPS: 12,000 - 18,000 (+60-80%)
- 平均延迟: ~0.6ms (-40%)
- P99 延迟: <3ms (-40%)

---

## 使用示例

### 零拷贝示例

```zig
const zero_copy = @import("zero_copy.zig");

// 创建零拷贝响应
var response = zero_copy.ZeroCopyResponse.init(allocator);
defer response.deinit();

response.setStatusLine("HTTP/1.1 200 OK\r\n");
response.addHeader("Content-Type: text/plain\r\n");
response.appendBody("Hello, World!");

// 直接写入（零拷贝）
try response writeTo(&writer);
```

### 内存池示例

```zig
const memory_pool = @import("memory_pool.zig");

// 创建内存池
var pool = memory_pool.MemoryPool.init(allocator, .{});
defer pool.deinit();

// 分配内存
const data = try pool.alloc(1024);
defer pool.free(data);

// 批量重置
pool.reset();
```

### 连接池示例

```zig
const connection_pool = @import("connection_pool.zig");

// 创建连接池
var pool = try connection_pool.ConnectionPool.init(allocator, .{
    .max_connections = 100,
    .max_idle_connections = 10,
});
defer pool.deinit();

// 获取连接
const conn = try pool.acquire("example.com", 80);
defer pool.release(conn);

// 使用连接发送请求
_ = try conn.stream.writer().writeAll("GET / HTTP/1.1\r\n\r\n");
```

### 缓冲区管理示例

```zig
const buffer_manager = @import("buffer_manager.zig");

// 创建缓冲区管理器
var manager = buffer_manager.BufferManager.init(allocator, .{});
defer manager.deinit();

// 预分配缓冲区
try manager.preallocate(10, 10);

// 获取缓冲区
const buffer = try manager.acquireReadBuffer();
defer manager.releaseReadBuffer(buffer);

// 获取统计
const stats = manager.getStats();
std.log.info("Reuse rate: {d:.2}%", .{
    buffer_manager.BufferStats.getReuseRate(stats)
});
```

---

## 最佳实践

### 1. 零拷贝

- 尽可能使用 `BufferView` 而不是复制数据
- 对于大型文件，使用 `ZeroCopyFileReader`
- 复用 `StringInterner` 处理重复字符串

### 2. 内存池

- 为请求作用域使用 `RequestArena`
- 为固定大小对象使用 `ObjectPool`
- 定期重置池以避免内存膨胀

### 3. 连接复用

- 合理设置 `max_idle_connections`
- 定期清理过期连接
- 监控连接池统计信息

### 4. 缓冲区管理

- 预分配缓冲区以减少运行时分配
- 监控复用率
- 合理配置缓冲区大小

---

## 性能监控

### 内存使用

```zig
const stats = pool.getStats();
std.log.info("Memory: {d}/{d} blocks, {d} bytes", .{
    stats.used_blocks,
    stats.total_blocks,
    stats.total_bytes,
});
```

### 连接统计

```zig
const stats = pool.getStats();
std.log.info("Connections: {d} active, {d} idle", .{
    stats.active_connections,
    stats.idle_connections,
});
```

### 缓冲区统计

```zig
const stats = manager.getStats();
const reuse_rate = BufferStats.getReuseRate(stats);
std.log.info("Buffer reuse rate: {d:.2}%", .{reuse_rate});
```

---

## 注意事项

### 1. Zig 版本兼容性

某些优化（如 `std.Thread.Mutex`）在 Zig 0.15.2 中不可用。当前实现已针对 0.15.2 进行了简化。

### 2. 平台差异

- `mmap` 在某些平台上可能不支持
- 原子操作在不同平台上有差异
- 线程模型因平台而异

### 3. 内存安全

- 确保正确释放缓冲区
- 注意缓冲区的生命周期
- 避免使用已释放的内存

---

## 未来改进

1. **支持 Zig 0.16+ API**
   - 添加完整的 Mutex 支持
   - 使用新的 Allocator API
   - 利用新的并发原语

2. **更智能的池管理**
   - 自适应池大小
   - 动态调整策略
   - 预测性分配

3. **更全面的监控**
   - 实时性能指标
   - 自动调优建议
   - 历史数据分析

---

## 许可证

MIT License
