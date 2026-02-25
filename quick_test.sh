#!/bin/bash
./zig-out/bin/zig_http 2>&1 &
SERVER_PID=$!
sleep 1
curl -s http://127.0.0.1:8080/static/ > /tmp/static_test.html 2>&1
echo "=== Static Response ==="
cat /tmp/static_test.html | head -30
kill $SERVER_PID 2>/dev/null
