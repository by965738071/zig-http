#!/bin/bash
# Start server in background
./zig-out/bin/zig_http > /tmp/server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "Testing /api/client endpoint..."
for i in {1..10}; do
    echo "Request $i:"
    curl -s http://127.0.0.1:8080/api/client 2>&1 | head -5
    echo ""
done

# Kill server
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

echo "Server log:"
cat /tmp/server.log | tail -20
