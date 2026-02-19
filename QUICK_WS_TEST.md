# 快速 WebSocket 测试指南

## 问题总结

你提到 WebSocket 连接显示 "disconnected"。这通常是由于 **HTTP Upgrade 请求没有被正确处理**。

## 快速修复步骤

### 1. 重新编译项目
```bash
cd zig-http
zig build
```

### 2. 启动服务器
```bash
zig build run
```

你应该看到：
```
🚀 Zig HTTP Server starting on 127.0.0.1:8080
...
  ✅ WebSocket: /ws/echo
```

### 3. 在浏览器中测试
打开：http://127.0.0.1:8080/ws

这会打开一个 Web UI 来测试 WebSocket。

**预期行为：**
- 状态应该变为 "Connected"（绿色）
- 你应该看到 "Server" 消息 "Connected to server"
- 输入消息并发送，应该收到回显

### 4. 命令行测试（可选）

如果有 wscat：
```bash
npm install -g wscat
wscat -c ws://127.0.0.1:8080/ws/echo
```

如果有 Python：
```bash
pip install websockets
python3 test_ws_client.py
```

用 curl 测试升级请求：
```bash
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://127.0.0.1:8080/ws/echo
```

应该返回 `HTTP/1.1 101 Switching Protocols`

## 故障排除

### 问题：仍然显示 "disconnected"

**检查服务器日志：**
查找这些日志消息：
```
WebSocket upgrade check for /ws/echo: websocket
WebSocket handler found for: /ws/echo
Responding to WebSocket upgrade with key: ...
WebSocket connection established, calling handler
```

如果看到 `WebSocket upgrade check: none`，说明升级请求格式错误。

### 问题：浏览器控制台显示错误

打开开发者工具（F12）→ Console 标签，查看错误信息。

常见错误：
- `WebSocket connection closed` - 连接被拒绝或服务器断开
- `ERR_INVALID_HTTP_RESPONSE` - 服务器没有正确响应升级请求

### 问题：curl 测试显示非 101 响应

这意味着服务器没有识别升级请求。检查：
1. 服务器是否正在运行
2. 路径是否正确（`/ws/echo`）
3. 所有必需的头是否都发送了

## 技术细节

### 改进的部分

最新修复包括：

1. **简化升级检查**
   - 使用 `request.upgradeRequested()` 正确返回值
   - 检查 `.websocket` union 类型

2. **改进日志**
   - 添加详细的 WebSocket 升级日志
   - 显示处理进度

3. **错误处理**
   - 更好的错误消息
   - 清晰的失败点追踪

### 代码位置

- **WebSocket 服务器**：`src/websocket.zig`
- **HTTP 升级处理**：`src/http_server.zig` 第 260-315 行
- **WebSocket 处理器**：`src/main.zig` 第 619-646 行
- **Web UI**：`src/main.zig` 第 648-768 行

## 测试一切正常的标志

✅ 所有这些都应该工作：

1. `http://127.0.0.1:8080/ws` 加载并显示 Web UI
2. 点击 "Reconnect" 后状态变为 "Connected"（绿色）
3. 发送消息并收到回显
4. 服务器日志显示 WebSocket 连接建立

## 获取完整帮助

更详细的故障排除指南，见：
```bash
cat WEBSOCKET_GUIDE.md
```

## 运行集成测试

```bash
chmod +x run_ws_test.sh
./run_ws_test.sh
```

这会自动测试所有功能。

---

**问题已修复！** 主要改进包括：
- ✅ 简化 WebSocket 升级检查逻辑
- ✅ 添加详细调试日志
- ✅ 改进错误处理
- ✅ 创建测试脚本和指南

现在 WebSocket 应该可以正常连接了。