#!/usr/bin/env bash
# mcp-server.test.sh — tests for the stdio MCP server wrapper.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
MCP_SERVER="$REPO_ROOT/mcp_server.py"

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# Test 1: initialize handshake with protocolVersion echoing
init_request='{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}'
resp=$(echo "$init_request" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp initialize returned empty response"
echo "$resp" | grep -q '"protocolVersion"[[:space:]]*:[[:space:]]*"2024-11-05"' || fail "mcp initialize failed to echo protocolVersion: $resp"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate-coder-mcp"' || fail "mcp initialize response name mismatch: $resp"
pass "mcp server initialize handshake (with version echoing)"

# Test 2: tools/list
list_request='{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}'
resp=$(echo "$list_request" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp tools/list returned empty response"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_contract"' || fail "mcp tools/list missing delegate_contract"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_exec"' || fail "mcp tools/list missing delegate_exec"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_read"' || fail "mcp tools/list missing delegate_read"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_doctor"' || fail "mcp tools/list missing delegate_doctor"
pass "mcp server list tools"

# Test 3: tools/call with unknown tool (-32601)
unknown_request='{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "does_not_exist"}}'
resp=$(echo "$unknown_request" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp unknown tool returned empty response"
echo "$resp" | grep -q '"code"[[:space:]]*:[[:space:]]*-32601' || fail "mcp unknown tool did not return error code -32601: $resp"
pass "mcp server unknown tool handling"

# Test 4: tools/call with invalid params (-32602)
invalid_request='{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "delegate_exec", "arguments": {}}}'
resp=$(echo "$invalid_request" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp invalid params returned empty response"
echo "$resp" | grep -q '"code"[[:space:]]*:[[:space:]]*-32602' || fail "mcp invalid params did not return error code -32602: $resp"
pass "mcp server invalid params validation"

# Test 5: Notification handling (no response printed to stdout)
notification='{"jsonrpc": "2.0", "method": "notifications/initialized"}'
resp=$(echo "$notification" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -z "$resp" ]] || fail "mcp notification generated a response on stdout: $resp"
pass "mcp server notification handling"

# Test 6: (a) initialize with unsupported protocolVersion "1999-01-01" fallback
unsupported_version_req='{"jsonrpc": "2.0", "id": 6, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}}'
resp=$(echo "$unsupported_version_req" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp initialize with unsupported version returned empty response"
echo "$resp" | grep -q '"protocolVersion"[[:space:]]*:[[:space:]]*"2024-11-05"' || fail "mcp unsupported version failed to fall back to latest supported version: $resp"
pass "mcp server initialize fallback on unsupported protocolVersion"

# Test 7: (b) tools/call for delegate_exec with invalid project_root returns -32602
invalid_root_req='{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "delegate_exec", "arguments": {"task": "test", "project_root": "/nope/does/not/exist"}}}'
resp=$(echo "$invalid_root_req" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp invalid project_root returned empty response"
echo "$resp" | grep -q '"code"[[:space:]]*:[[:space:]]*-32602' || fail "mcp invalid project_root did not return error code -32602: $resp"
echo "$resp" | grep -q "Invalid params: project_root does not exist or is not a directory" || fail "mcp invalid project_root did not report the validation error message: $resp"
pass "mcp server invalid project_root validation"

echo "All MCP server tests passed."
