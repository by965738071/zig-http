# Utils Module

工具模块提供共享的实用函数和测试工具。

## 导出的模块

### test_utils
测试工具函数，用于验证安全和功能测试：
- `testPathSafetyValidation()` - 路径安全验证
- `testFilenameSafetyValidation()` - 文件名安全验证
- `testHttpMethodValidation()` - HTTP 方法验证
- `testSqlInjectionDetection()` - SQL 注入检测
- `testXssDetection()` - XSS 检测

### benchmark
性能测试工具：
- `benchmark()` - 执行基准测试

## 使用示例

### 运行测试用例

```zig
const test_utils = @import("utils/lib.zig").test_utils;

// 运行路径安全测试
try test_utils.testPathSafetyValidation();

// 运行 XSS 检测测试
try test_utils.testXssDetection();
```

### 运行基准测试

```zig
const benchmark = @import("utils/lib.zig").benchmark;

const result = try benchmark("alloc_free", 1000, struct {
    fn run() anyerror!void {
        const buf = try std.heap.page_allocator.alloc(u8, 256);
        std.heap.page_allocator.free(buf);
    }
}.run);

std.log.info("Benchmark: {s}", .{result.name});
std.log.info("Iterations: {d}", .{result.iterations});
std.log.info("Avg time: {d} ms", .{result.avg_time_ms});
```

## 添加新的工具函数

1. 在 `src/` 目录中创建或编辑工具文件
2. 在 `src/utils/lib.zig` 中导出

### 示例

```zig
// src/utils/my_utils.zig
pub fn calculateHash(data: []const u8) u64 {
    var hash: u64 = 5381;
    for (data) |byte| {
        hash = ((hash << 5) + hash) + byte;
    }
    return hash;
}
```

```zig
// src/utils/lib.zig
pub const my_utils = @import("my_utils.zig");
```

## 架构原则

工具模块遵循以下原则：

1. **纯函数** - 工具函数应该是纯函数，没有副作用
2. **可重用性** - 设计为可在多个地方重用
3. **简单性** - 保持简单和专注
4. **无依赖** - 尽量减少对其他模块的依赖
