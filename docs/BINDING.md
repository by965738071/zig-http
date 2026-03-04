# 参数绑定 (Parameter Binding)

Zig HTTP 框架提供了强大的参数绑定功能，可以自动将 HTTP 请求参数绑定到结构体上。

## 功能特性

- **自动类型转换**：将字符串参数转换为正确的类型（u32, i32, f64, bool 等）
- **多来源绑定**：支持从查询参数、表单数据、路径参数、JSON body 获取数据
- **可选字段**：使用 `?` 标记可选字段
- **默认值**：可以为字段设置默认值
- **错误处理**：自动收集和返回绑定错误
- **验证支持**：轻松添加自定义验证逻辑

## 快速开始

### 1. 定义数据模型

```zig
const User = struct {
    id: ?u32 = null,        // 可选字段，有默认值
    name: []const u8,        // 必填字段
    email: []const u8,        // 必填字段
    age: u32,                // 必填字段
    is_active: bool = true,  // 有默认值
};
```

### 2. 使用方式

#### 方式一：使用 `bind()` 方法（推荐）

```zig
pub fn addUserHandler(ctx: *Context) !void {
    // 自动绑定参数到 User 结构体
    const user = try ctx.bindOrError(User);

    // 使用绑定的数据
    try ctx.response.writeJSON(.{
        .status = "success",
        .user = user,
    });
}
```

#### 方式二：使用 `bind` 装饰器

```zig
pub fn addUserHandler(ctx: *Context, user: User) !void {
    // user 参数已经自动绑定
    try ctx.response.writeJSON(.{
        .status = "success",
        .user = user,
    });
}

// 创建绑定的处理器
const boundAddUserHandler = bind(addUserHandler);
```

#### 方式三：手动绑定（带自定义验证）

```zig
pub fn createUserHandler(ctx: *Context) !void {
    var result = ctx.bind(User);
    defer result.deinit(ctx.allocator);

    if (result.has_errors) {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Validation failed",
            .errors = result.errors.items,
        });
        return;
    }

    const user = binder.getBoundValue(User, &result).?;

    // 自定义验证
    if (user.age < 18) {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "User must be at least 18 years old",
        });
        return;
    }

    // 创建用户...
}
```

## 绑定优先级

参数从以下来源按优先级绑定：

1. **查询参数** (Query Parameters) - `?name=value`
2. **表单数据** (Form Data) - POST `application/x-www-form-urlencoded`
3. **路径参数** (Path Parameters) - `/users/:id`
4. **JSON Body** - 使用 `bindJSON()`

## 支持的类型

| Zig 类型 | 说明 | 示例 |
|---------|------|------|
| `[]const u8` | 字符串 | `"John"` |
| `u8, u16, u32, u64` | 无符号整数 | `42` |
| `i8, i16, i32, i64` | 有符号整数 | `-10` |
| `f32, f64` | 浮点数 | `3.14` |
| `bool` | 布尔值 | `"true"` / `"false"` |
| `?T` | 可选类型 | `null` 或 `T` |
| `enum` | 枚举 | 枚举名称（不区分大小写） |

## 完整示例

### 示例 1: 用户注册

```zig
// 数据模型
pub const RegisterRequest = struct {
    username: []const u8,
    password: []const u8,
    email: []const u8,
    age: u32,
    agree_to_terms: bool = false,
};

// 处理器
pub fn registerHandler(ctx: *Context, req: RegisterRequest) !void {
    // 验证
    if (!req.agree_to_terms) {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Must agree to terms",
        });
        return;
    }

    // 验证密码长度
    if (req.password.len < 8) {
        try ctx.response.setStatus(http.Status.bad_request);
        try ctx.response.writeJSON(.{
            .status = "error",
            .message = "Password must be at least 8 characters",
        });
        return;
    }

    // 创建用户...
    try ctx.response.writeJSON(.{
        .status = "success",
        .message = "User registered",
        .user = req,
    });
}

// 路由
router.addRoute("POST", "/api/register", bind(registerHandler));
```

**请求示例**：
```
POST /api/register?username=john&password=secretpass&email=john@example.com&age=25&agree_to_terms=true
```

### 示例 2: 产品搜索

```zig
pub const SearchRequest = struct {
    query: ?[]const u8 = null,      // 可选
    category: ?[]const u8 = null,   // 可选
    min_price: ?f64 = null,        // 可选
    max_price: ?f64 = null,        // 可选
    page: u32 = 1,                 // 默认值
    limit: u32 = 10,               // 默认值
};

pub fn searchHandler(ctx: *Context, req: SearchRequest) !void {
    // 构建查询...
    const products = try searchProducts(req);

    try ctx.response.writeJSON(.{
        .status = "success",
        .page = req.page,
        .results = products,
    });
}
```

**请求示例**：
```
GET /api/products/search?query=phone&category=electronics&min_price=100&max_price=1000&page=1
```

### 示例 3: JSON Body 绑定

```zig
pub const UpdateUserRequest = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    age: ?u32 = null,
};

pub fn updateUserHandler(ctx: *Context) !void {
    // 从 JSON body 绑定
    const update = try ctx.bindJSON(UpdateUserRequest);

    try ctx.response.writeJSON(.{
        .status = "success",
        .updated = update,
    });
}
```

**请求示例**：
```json
PUT /api/users/123
Content-Type: application/json

{
  "name": "John Doe",
  "age": 31
}
```

## 错误响应格式

当绑定失败时，返回如下格式的错误：

```json
{
  "status": "error",
  "message": "Parameter binding failed",
  "errors": [
    {
      "field": "age",
      "error": "MissingRequiredParameter",
      "message": "Required parameter is missing"
    },
    {
      "field": "email",
      "error": "TypeConversionFailed",
      "message": "Failed to parse field: ..."
    }
  ]
}
```

## 高级用法

### 枚举类型

```zig
pub const UserRole = enum {
    admin,
    user,
    guest,
};

pub const CreateUserRequest = struct {
    username: []const u8,
    role: UserRole = UserRole.user,  // 默认值
};

// 请求: ?username=john&role=admin
```

### 自定义验证中间件

```zig
pub fn validateAgeMiddleware(next: Handler) Handler {
    return struct {
        fn handler(ctx: *Context) !void {
            const user = try ctx.bindOrError(User);

            if (user.age < 18) {
                try ctx.response.setStatus(http.Status.bad_request);
                try ctx.response.writeJSON(.{
                    .status = "error",
                    .message = "Must be 18 or older",
                });
                return;
            }

            try next(ctx);
        }
    }.handler;
}

// 使用
router.addRoute("POST", "/api/users", validateAgeMiddleware(addUserHandler));
```

## 最佳实践

1. **使用专门的 DTO**：不要直接使用数据库模型，创建专门的数据传输对象
2. **显式字段**：只绑定需要的字段，避免过度绑定
3. **验证数据**：在绑定后添加业务逻辑验证
4. **默认值**：为可选字段提供合理的默认值
5. **类型安全**：利用 Zig 的类型系统确保数据完整性

## 对比其他框架

| 功能 | Spring Boot | Express | Zig HTTP |
|------|-------------|---------|----------|
| 自动绑定 | ✅ @ModelAttribute | ✅ body-parser | ✅ bind() |
| 类型转换 | ✅ | ✅ | ✅ |
| 验证 | ✅ @Valid | 手动 | 手动 |
| 可选字段 | ✅ Optional | 手动 | ✅ ?T |
| 默认值 | ✅ @DefaultValue | 手动 | ✅ = value |
| 多来源绑定 | ✅ | 需要配置 | ✅ 自动 |

## API 参考

### Context 方法

```zig
// 绑定并自动处理错误
pub fn bindOrError(ctx: *Context, comptime T: type) !T

// 绑定返回 BindingResult（手动处理错误）
pub fn bind(ctx: *Context, comptime T: type) binder.BindingResult

// 绑定 JSON body
pub fn bindJSON(ctx: *Context, comptime T: type) !T
```

### binder 模块

```zig
// 手动绑定
pub fn bindRequest(comptime T: type, ctx: *Context) BindingResult

// 绑定 JSON
pub fn bindJSONBody(comptime T: type, ctx: *Context) !T

// 获取绑定值
pub fn getBoundValue(comptime T: type, result: *const BindingResult) ?*const T
```

### BindingResult

```zig
pub const BindingResult = struct {
    target: ?*const anyopaque,           // 绑定的值
    errors: std.ArrayList(BindingErrorEntry),  // 错误列表
    has_errors: bool,                     // 是否有错误

    pub fn deinit(self: *BindingResult) void
};
```
