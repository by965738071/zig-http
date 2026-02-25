#!/bin/sh
./zig-out/bin/zig_http &
PID=$!
sleep 2
echo "Testing /static/ endpoint..."
curl -s http://127.0.0.1:8080/static/ 2>&1 | head -20
kill $PID 2>/dev/null
wait $PID 2>/dev/null
