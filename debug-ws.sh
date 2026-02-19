#!/bin/bash

# WebSocket Debugging Script

# Start server in background
echo "Starting server..."
./zig-out/bin/zig_http > server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to start
sleep 2

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start"
    cat server.log
    exit 1
fi

echo "Server started successfully"
echo ""

# Test 1: GET /ws page
echo "Test 1: GET /ws page"
curl -v http://127.0.0.1:8080/ws 2>&1 | head -20
echo ""
echo ""

# Test 2: WebSocket upgrade with verbose headers
echo "Test 2: WebSocket upgrade request (curl with headers)"
curl -v -i -N \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    http://127.0.0.1:8080/ws/echo 2>&1 | head -30
echo ""
echo ""

# Show server logs
echo "Server logs:"
sleep 1
cat server.log

# Kill server
echo ""
echo "Stopping server..."
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo "Debug test complete"
