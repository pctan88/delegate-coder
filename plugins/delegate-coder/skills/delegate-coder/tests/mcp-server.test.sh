#!/usr/bin/env bash
# mcp-server.test.sh — tests for the stdio MCP server wrapper.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
MCP_SERVER="$REPO_ROOT/mcp_server.py"

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# Test 1: initialize handshake
init_request='{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}'
resp=$(echo "$init_request" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp initialize returned empty response"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate-coder-mcp"' || fail "mcp initialize response name mismatch: $resp"
pass "mcp server initialize handshake"

# Test 2: tools/list
list_request='{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}'
resp=$(echo "$list_request" | python3 "$MCP_SERVER" 2>/dev/null)
[[ -n "$resp" ]] || fail "mcp tools/list returned empty response"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_contract"' || fail "mcp tools/list missing delegate_contract"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_exec"' || fail "mcp tools/list missing delegate_exec"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_read"' || fail "mcp tools/list missing delegate_read"
echo "$resp" | grep -q '"name"[[:space:]]*:[[:space:]]*"delegate_doctor"' || fail "mcp tools/list missing delegate_doctor"
pass "mcp server list tools"

echo "All MCP server tests passed."
