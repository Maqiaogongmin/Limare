#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PORT=5173
while lsof -i :$PORT >/dev/null 2>&1; do
  PORT=$((PORT + 1))
done

echo "=========================================="
echo " Starting Limare Website Preview"
echo " Local URL: http://localhost:$PORT"
echo "=========================================="

# Start static preview server
npx vite preview --port $PORT &
SERVER_PID=$!

trap 'kill $SERVER_PID 2>/dev/null' EXIT INT TERM

# Wait for server readiness then open in default browser
for i in {1..30}; do
  if curl -sf "http://localhost:$PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

open "http://localhost:$PORT"

echo "Preview server running. Press Ctrl+C in this terminal to stop."
wait $SERVER_PID
