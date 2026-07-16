#!/usr/bin/env python3
"""mcp_server.py — Stdio-based Model Context Protocol (MCP) server for delegate-coder.

Allows any MCP client (such as Antigravity or Claude Code) to delegate
execution-heavy tasks or run Task Contracts using local worker agents.
"""
import sys
import json
import subprocess
import os
import pathlib
import argparse
import urllib.parse
import uuid
import queue
import socketserver
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

# Setup absolute paths relative to repository root
ROOT_DIR = pathlib.Path(__file__).parent.resolve()
DELEGATE_SH = ROOT_DIR / "plugins" / "delegate-coder" / "skills" / "delegate-coder" / "scripts" / "delegate.sh"
DOCTOR_SH = ROOT_DIR / "plugins" / "delegate-coder" / "skills" / "delegate-coder" / "scripts" / "doctor.sh"

SUPPORTED_PROTOCOL_VERSIONS = ["2024-11-05"]

PROJECT_LOCKS = {}
PROJECT_LOCKS_LOCK = threading.Lock()

def run_command(args, cwd=None):
    try:
        env = os.environ.copy()
        # Default to the process's active CWD (which matches the client's active project workspace)
        target_cwd = cwd if cwd is not None else os.getcwd()
        resolved_path = str(pathlib.Path(target_cwd).resolve(strict=True))

        with PROJECT_LOCKS_LOCK:
            if resolved_path not in PROJECT_LOCKS:
                PROJECT_LOCKS[resolved_path] = threading.Lock()
            lock = PROJECT_LOCKS[resolved_path]

        with lock:
            res = subprocess.run(
                args,
                capture_output=True,
                text=True,
                cwd=resolved_path,
                env=env,
                timeout=1200  # 20-minute execution timeout to prevent hung loops
            )
            return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "mcp_server: command execution timed out (20-minute limit exceeded)"
    except Exception as e:
        return 1, "", str(e)

def handle_request(req):
    if not isinstance(req, dict) or "method" not in req:
        return {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid request"}}
    
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params", {})
    
    if method == "initialize":
        requested_version = params.get("protocolVersion")
        if requested_version in SUPPORTED_PROTOCOL_VERSIONS:
            negotiated_version = requested_version
        else:
            negotiated_version = SUPPORTED_PROTOCOL_VERSIONS[-1]
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": negotiated_version,
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "delegate-coder-mcp",
                    "version": "0.1.0"
                }
            }
        }
        
    elif method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "tools": [
                    {
                        "name": "delegate_contract",
                        "description": "Delegate a bounded implementation/refactoring task using a single-file Task Contract. Restores target file and Git index on failure.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "target_file": {
                                    "type": "string",
                                    "description": "The target file path relative to repository root to modify (e.g. 'src/utils.py')"
                                },
                                "instructions": {
                                    "type": "string",
                                    "description": "The objective modification instructions"
                                },
                                "test_command": {
                                    "type": "string",
                                    "description": "The objective command to run to verify the changes"
                                },
                                "context_files": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": "Optional list of read-only reference context files to help the worker agent"
                                },
                                "project_root": {
                                    "type": "string",
                                    "description": "Optional absolute path to the project root directory. Defaults to client current directory."
                                }
                            },
                            "required": ["target_file", "instructions", "test_command"]
                        }
                    },
                    {
                        "name": "delegate_exec",
                        "description": "Run a general implementation task using the configured worker agent (requires DELEGATE_AGENT or config).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "task": {
                                    "type": "string",
                                    "description": "The task specification / execution prompt"
                                },
                                "project_root": {
                                    "type": "string",
                                    "description": "Optional absolute path to the project root directory. Defaults to client current directory."
                                }
                            },
                            "required": ["task"]
                        }
                    },
                    {
                        "name": "delegate_read",
                        "description": "Run a codebase reading or analysis task using the configured worker agent (read-only mode).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "task": {
                                    "type": "string",
                                    "description": "The read/analysis query"
                                },
                                "project_root": {
                                    "type": "string",
                                    "description": "Optional absolute path to the project root directory. Defaults to client current directory."
                                }
                            },
                            "required": ["task"]
                        }
                    },
                    {
                        "name": "delegate_doctor",
                        "description": "Run the health-check doctor tool to verify installed worker agents and credentials.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "all": {
                                    "type": "boolean",
                                    "description": "If true, checks all known agents instead of just the configured one"
                                },
                                "project_root": {
                                    "type": "string",
                                    "description": "Optional absolute path to the project root directory. Defaults to client current directory."
                                }
                            }
                        }
                    }
                ]
            }
        }
        
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments", {})
        project_root = args.get("project_root")
        
        if project_root is not None and not pathlib.Path(project_root).is_dir():
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32602,
                    "message": f"Invalid params: project_root does not exist or is not a directory: {project_root}"
                }
            }

        if name == "delegate_contract":
            target_file = args.get("target_file")
            instructions = args.get("instructions")
            test_command = args.get("test_command")
            context_files = args.get("context_files")
            
            # Server-side argument validation
            if not target_file or not instructions or not test_command:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params: target_file, instructions, and test_command are required"
                    }
                }

            contract_obj = {
                "target_file": target_file,
                "instructions": instructions,
                "test_command": test_command
            }
            if context_files is not None:
                contract_obj["context_files"] = context_files
                
            contract_str = json.dumps(contract_obj)
            
            rc, stdout, stderr = run_command(["bash", str(DELEGATE_SH), "contract", contract_str], cwd=project_root)
            
            text = f"Exit code: {rc}\n\nSTDOUT:\n{stdout}\n\nSTDERR:\n{stderr}"
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": text}],
                    "isError": rc != 0
                }
            }
            
        elif name == "delegate_exec":
            task = args.get("task")
            if not task:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params: task is required"
                    }
                }
            rc, stdout, stderr = run_command(["bash", str(DELEGATE_SH), "exec", task], cwd=project_root)
            text = f"Exit code: {rc}\n\nSTDOUT:\n{stdout}\n\nSTDERR:\n{stderr}"
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": text}],
                    "isError": rc != 0
                }
            }
            
        elif name == "delegate_read":
            task = args.get("task")
            if not task:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params: task is required"
                    }
                }
            rc, stdout, stderr = run_command(["bash", str(DELEGATE_SH), "read", task], cwd=project_root)
            text = f"Exit code: {rc}\n\nSTDOUT:\n{stdout}\n\nSTDERR:\n{stderr}"
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": text}],
                    "isError": rc != 0
                }
            }
            
        elif name == "delegate_doctor":
            check_all = args.get("all", False)
            cmd = ["bash", str(DOCTOR_SH)]
            if check_all:
                cmd.append("--all")
            rc, stdout, stderr = run_command(cmd, cwd=project_root)
            text = f"Exit code: {rc}\n\nSTDOUT:\n{stdout}\n\nSTDERR:\n{stderr}"
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": text}],
                    "isError": rc != 0
                }
            }
            
        else:
            return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"Unknown tool: {name}"}}

    else:
        # Handshake notifications or initialize notifications do not expect replies
        if req_id is not None:
            return {"jsonrpc": "2.0", "id": req_id, "result": {}}
        return None

# --- HTTP/SSE server implementation ---
CLIENTS = {}
CLIENTS_LOCK = threading.Lock()

class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True

class MCPSSEHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Redirect request logs to stderr to keep stdout completely clean for JSON-RPC
        sys.stderr.write(f"mcp_server [SSE]: {format % args}\n")
        sys.stderr.flush()

    def send_http_error(self, code, message):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Connection", "close")
        origin = self.headers.get("Origin")
        if origin and self.is_origin_allowed():
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(message.encode("utf-8"))
        self.close_connection = True

    def is_origin_allowed(self):
        origin = self.headers.get("Origin")
        if origin is not None:
            try:
                parsed = urllib.parse.urlparse(origin)
                if parsed.scheme not in ("http", "https"):
                    return False
                hostname = (parsed.hostname or "").lower()
                if hostname not in ("127.0.0.1", "localhost"):
                    return False
            except Exception:
                return False
        return True

    def is_authorized(self):
        auth_token = os.environ.get("MCP_AUTH_TOKEN")
        if not auth_token:
            return True
        auth_header = self.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            return False
        token = auth_header[7:].strip()
        return token == auth_token

    def preflight_check(self):
        if not self.is_origin_allowed():
            self.send_http_error(403, "Forbidden: Cross-Origin request denied")
            return False

        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("/sse", "/message"):
            if not self.is_authorized():
                self.send_http_error(401, "Unauthorized: Missing or invalid Authorization token")
                return False
        return True

    def do_OPTIONS(self):
        if not self.is_origin_allowed():
            self.send_response(403)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            return
        self.send_response(204)
        origin = self.headers.get("Origin")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_DELETE(self):
        if not self.preflight_check():
            return
        self.send_response(200)
        origin = self.headers.get("Origin")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()

    def do_GET(self):
        if not self.preflight_check():
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/message":
            self.send_http_error(405, "Method Not Allowed: GET /message is not supported")
            return

        if parsed.path == "/sse":
            client_id = str(uuid.uuid4())
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            origin = self.headers.get("Origin")
            if origin:
                self.send_header("Access-Control-Allow-Origin", origin)
            self.end_headers()

            # Client must POST client messages to /message?client_id=client_id
            msg = f"event: endpoint\ndata: /message?client_id={client_id}\n\n"
            self.wfile.write(msg.encode("utf-8"))
            self.wfile.flush()

            q = queue.Queue()
            with CLIENTS_LOCK:
                CLIENTS[client_id] = q

            sys.stderr.write(f"mcp_server [SSE]: Client connected: {client_id}\n")
            sys.stderr.flush()

            try:
                while True:
                    try:
                        data = q.get(timeout=2.0)
                        if data is None:
                            break
                        msg = f"event: message\ndata: {json.dumps(data)}\n\n"
                        self.wfile.write(msg.encode("utf-8"))
                        self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
            except Exception as e:
                sys.stderr.write(f"mcp_server [SSE]: Error sending event to {client_id}: {e}\n")
                sys.stderr.flush()
            finally:
                with CLIENTS_LOCK:
                    CLIENTS.pop(client_id, None)
                sys.stderr.write(f"mcp_server [SSE]: Client disconnected: {client_id}\n")
                sys.stderr.flush()
        else:
            self.send_response(404)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

    def do_POST(self):
        if not self.preflight_check():
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/sse":
            self.send_http_error(405, "Method Not Allowed: POST /sse is not supported")
            return

        content_length_str = self.headers.get("Content-Length")
        if content_length_str is None:
            self.send_http_error(400, "Bad Request: Missing Content-Length header")
            return
        try:
            content_length = int(content_length_str)
        except ValueError:
            self.send_http_error(400, "Bad Request: Invalid Content-Length header")
            return

        if content_length > 1048576:  # 1MB
            self.send_http_error(413, "Payload Too Large: Limit is 1MB")
            return

        try:
            body = self.rfile.read(content_length).decode("utf-8")
        except Exception as e:
            self.send_http_error(400, f"Bad Request: Error reading body: {e}")
            return

        sys.stderr.write(f"mcp_server [SSE]: POST {self.path} body: {body}\n")
        sys.stderr.flush()

        try:
            req = json.loads(body)
        except Exception:
            self.send_http_error(400, "Bad Request: Malformed JSON")
            return

        query = urllib.parse.parse_qs(parsed.query)
        client_id = query.get("client_id", [None])[0]

        if parsed.path == "/message":
            with CLIENTS_LOCK:
                is_active = client_id and client_id in CLIENTS
            if not is_active:
                self.send_http_error(404, "Not Found: Client session not found or inactive")
                return

        resp = handle_request(req)

        with CLIENTS_LOCK:
            use_sse = client_id and client_id in CLIENTS

        if use_sse:
            with CLIENTS_LOCK:
                q = CLIENTS.get(client_id)
            if q is not None:
                q.put(resp)
            self.send_response(202)
            origin = self.headers.get("Origin")
            if origin:
                self.send_header("Access-Control-Allow-Origin", origin)
            self.end_headers()
            sys.stderr.write(f"mcp_server [SSE]: Queued response for client {client_id}\n")
            sys.stderr.flush()
        else:
            if resp is not None:
                accept = self.headers.get("Accept", "")
                is_event_stream = "text/event-stream" in accept or parsed.path == "/sse"

                self.send_response(200)
                origin = self.headers.get("Origin")
                if origin:
                    self.send_header("Access-Control-Allow-Origin", origin)

                if is_event_stream:
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Connection", "keep-alive")
                    self.end_headers()
                    resp_str = f"event: message\ndata: {json.dumps(resp)}\n\n"
                    self.wfile.write(resp_str.encode("utf-8"))
                    sys.stderr.write(f"mcp_server [SSE]: Responded via Streamable HTTP: {resp_str}\n")
                    sys.stderr.flush()
                else:
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    resp_str = json.dumps(resp)
                    self.wfile.write(resp_str.encode("utf-8"))
                    sys.stderr.write(f"mcp_server [SSE]: Responded directly in JSON body: {resp_str}\n")
                    sys.stderr.flush()
            else:
                self.send_response(202)
                origin = self.headers.get("Origin")
                if origin:
                    self.send_header("Access-Control-Allow-Origin", origin)
                self.end_headers()
                sys.stderr.write("mcp_server [SSE]: Response: 202 Accepted\n")
                sys.stderr.flush()

def run_sse_server(port):
    sys.stderr.write(f"mcp_server [SSE]: Starting HTTP/SSE server on port {port}...\n")
    sys.stderr.flush()
    server = ThreadingHTTPServer(("127.0.0.1", port), MCPSSEHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        sys.stderr.write("mcp_server [SSE]: Server stopped.\n")
        sys.stderr.flush()

def main():
    parser = argparse.ArgumentParser(description="delegate-coder MCP Server")
    parser.add_argument("--port", type=int, help="Run as an HTTP/SSE server on the specified port instead of stdio")
    args_parsed = parser.parse_args()

    if args_parsed.port:
        run_sse_server(args_parsed.port)
    else:
        sys.stderr.write("delegate-coder-mcp started in stdio mode\n")
        sys.stderr.flush()
        while True:
            try:
                line = sys.stdin.readline()
                if not line:
                    break
                req = json.loads(line)
                resp = handle_request(req)
                if resp is not None:
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()
            except KeyboardInterrupt:
                break
            except Exception as e:
                sys.stderr.write(f"Error handling request: {e}\n")
                sys.stderr.flush()

if __name__ == "__main__":
    main()
