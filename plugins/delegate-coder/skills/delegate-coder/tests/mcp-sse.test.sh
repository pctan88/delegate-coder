#!/usr/bin/env bash
# mcp-sse.test.sh — tests for the HTTP/SSE MCP server wrapper.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
MCP_SERVER="$REPO_ROOT/mcp_server.py"
HELPER_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/mcp_sse_test_helper.py"

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

find_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

PORT=$(find_free_port)

python3 "$MCP_SERVER" --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

for idx in {1..50}; do
  if python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), timeout=0.1)" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if ! python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), timeout=0.1)" 2>/dev/null; then
  fail "mcp sse server failed to start on port $PORT"
fi

python3 "$HELPER_SCRIPT" "$PORT" || fail "MCP HTTP/SSE helper tests failed"

pass "All MCP HTTP/SSE wrapper compliance and security checks passed"
