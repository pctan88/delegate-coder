import urllib.request
import urllib.parse
import json
import threading
import queue
import time
import os
import sys
import subprocess
import socket
import uuid

def find_free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port

class TestServerProcess:
    def __init__(self, auth_token=None):
        self.port = find_free_port()
        self.auth_token = auth_token
        self.proc = None

    def start(self):
        env = os.environ.copy()
        if self.auth_token:
            env["MCP_AUTH_TOKEN"] = self.auth_token
        else:
            env.pop("MCP_AUTH_TOKEN", None)
            
        mcp_server_path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "..", "mcp_server.py")
        mcp_server_path = os.path.abspath(mcp_server_path)
        
        self.proc = subprocess.Popen(
            [sys.executable, mcp_server_path, "--port", str(self.port)],
            env=env,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE
        )
        # Wait for port to become active
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            self.stop()
            raise RuntimeError("Server failed to start in time")

    def stop(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait()

def test_sse_spec_compliance(port):
    base_url = f"http://127.0.0.1:{port}"
    
    req = urllib.request.Request(f"{base_url}/sse", method="GET")
    sse_conn = urllib.request.urlopen(req)
    
    line1 = sse_conn.readline().decode('utf-8').strip()
    line2 = sse_conn.readline().decode('utf-8').strip()
    sse_conn.readline()
    
    assert line1 == "event: endpoint", f"Expected event: endpoint, got: {line1}"
    assert line2.startswith("data: /message?client_id="), f"Expected data: /message?client_id=..., got: {line2}"
    client_id = line2[len("data: /message?client_id="):]
    
    msg_queue = queue.Queue()
    stop_event = threading.Event()
    
    def read_stream():
        try:
            while not stop_event.is_set():
                ev_line = sse_conn.readline().decode('utf-8').strip()
                if not ev_line:
                    continue
                if ev_line.startswith("event: "):
                    ev_type = ev_line[7:]
                    data_line = sse_conn.readline().decode('utf-8').strip()
                    sse_conn.readline()
                    if data_line.startswith("data: "):
                        data_val = data_line[6:]
                        msg_queue.put((ev_type, data_val))
        except Exception:
            pass

    t = threading.Thread(target=read_stream, daemon=True)
    t.start()
    
    try:
        post_url = f"{base_url}/message?client_id={client_id}"
        init_body = json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2024-11-05"}
        }).encode("utf-8")
        
        post_req = urllib.request.Request(
            post_url,
            data=init_body,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(post_req) as resp:
            assert resp.status == 202, f"Expected 202 Accepted, got: {resp.status}"
            resp_body = resp.read().decode('utf-8')
            assert resp_body == "", f"Expected empty response body, got: {resp_body}"
            
        ev_type, ev_data = msg_queue.get(timeout=10.0)
        assert ev_type == "message", f"Expected event type 'message', got: {ev_type}"
        res_json = json.loads(ev_data)
        assert res_json.get("id") == 1
        assert "result" in res_json
        assert res_json["result"]["protocolVersion"] == "2024-11-05"
        
        list_body = json.dumps({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        }).encode("utf-8")
        
        post_req = urllib.request.Request(
            post_url,
            data=list_body,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(post_req) as resp:
            assert resp.status == 202, f"Expected 202 Accepted, got: {resp.status}"
            
        ev_type, ev_data = msg_queue.get(timeout=10.0)
        assert ev_type == "message", f"Expected event type 'message', got: {ev_type}"
        res_json = json.loads(ev_data)
        assert res_json.get("id") == 2
        assert len(res_json["result"]["tools"]) > 0
        
    finally:
        stop_event.set()
        sse_conn.close()

def test_cors_and_token_auth(port):
    base_url = f"http://127.0.0.1:{port}"
    
    req = urllib.request.Request(f"{base_url}/sse", headers={"Origin": "https://evil.example"}, method="GET")
    try:
        urllib.request.urlopen(req)
        assert False, "Expected 403 Forbidden for Origin: https://evil.example"
    except urllib.error.HTTPError as e:
        assert e.code == 403, f"Expected 403, got: {e.code}"
        
    req = urllib.request.Request(f"{base_url}/sse", headers={"Origin": "http://localhost:3000"}, method="GET")
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        assert resp.headers.get("Access-Control-Allow-Origin") == "http://localhost:3000"

    auth_server = TestServerProcess(auth_token="secret-token-123")
    auth_server.start()
    try:
        auth_base = f"http://127.0.0.1:{auth_server.port}"
        
        req = urllib.request.Request(f"{auth_base}/sse", method="GET")
        try:
            urllib.request.urlopen(req)
            assert False, "Expected 401 for missing token"
        except urllib.error.HTTPError as e:
            assert e.code == 401, f"Expected 401, got: {e.code}"
            
        req = urllib.request.Request(f"{auth_base}/sse", headers={"Authorization": "Bearer wrong-token"}, method="GET")
        try:
            urllib.request.urlopen(req)
            assert False, "Expected 401 for wrong token"
        except urllib.error.HTTPError as e:
            assert e.code == 401, f"Expected 401, got: {e.code}"
            
        req = urllib.request.Request(f"{auth_base}/sse", headers={"Authorization": "Bearer secret-token-123"}, method="GET")
        with urllib.request.urlopen(req) as resp:
            assert resp.status == 200
    finally:
        auth_server.stop()

def test_client_id_validation(port):
    base_url = f"http://127.0.0.1:{port}"
    
    fake_client_id = str(uuid.uuid4())
    call_body = json.dumps({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "delegate_doctor",
            "arguments": {"all": False}
        }
    }).encode("utf-8")
    
    req = urllib.request.Request(
        f"{base_url}/message?client_id={fake_client_id}",
        data=call_body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    
    try:
        urllib.request.urlopen(req)
        assert False, "Expected 404 Not Found for fake client_id"
    except urllib.error.HTTPError as e:
        assert e.code == 404, f"Expected 404, got: {e.code}"
        resp_text = e.read().decode('utf-8')
        assert "Client session not found or inactive" in resp_text

def test_concurrency_safety(port):
    base_url = f"http://127.0.0.1:{port}"
    results = []
    errors = []
    
    def run_call(thread_id):
        call_body = json.dumps({
            "jsonrpc": "2.0",
            "id": 100 + thread_id,
            "method": "tools/call",
            "params": {
                "name": "delegate_doctor",
                "arguments": {"all": False}
            }
        }).encode("utf-8")
        
        req = urllib.request.Request(
            f"{base_url}/",
            data=call_body,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        try:
            with urllib.request.urlopen(req) as resp:
                assert resp.status == 200
                res_body = json.loads(resp.read().decode('utf-8'))
                results.append((thread_id, res_body))
        except Exception as e:
            errors.append((thread_id, str(e)))

    t1 = threading.Thread(target=run_call, args=(1,))
    t2 = threading.Thread(target=run_call, args=(2,))
    
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    
    assert len(errors) == 0, f"Got concurrency errors: {errors}"
    assert len(results) == 2, f"Expected 2 results, got: {len(results)}"
    
    for tid, res in results:
        assert "result" in res
        assert "error" not in res

def test_request_robustness(port):
    def send_raw_http(request_bytes):
        s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
        try:
            try:
                s.sendall(request_bytes)
            except (BrokenPipeError, ConnectionResetError):
                pass
            response = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                response += chunk
            return response
        finally:
            s.close()

    req_missing_cl = b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\r\n{}"
    resp_missing = send_raw_http(req_missing_cl)
    assert b"HTTP/1.1 400" in resp_missing, f"Expected HTTP 400, got: {resp_missing.decode('utf-8')}"
    
    req_invalid_cl = b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\nContent-Type: application/json\r\n\r\n{}"
    resp_invalid = send_raw_http(req_invalid_cl)
    assert b"HTTP/1.1 400" in resp_invalid, f"Expected HTTP 400, got: {resp_invalid.decode('utf-8')}"

    # Payload Too Large > 1MB (send header only, no body, to prevent early socket closure RST)
    req_large = b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1048580\r\nContent-Type: application/json\r\n\r\n"
    resp_large = send_raw_http(req_large)
    assert b"HTTP/1.1 413" in resp_large, f"Expected HTTP 413, got: {resp_large.decode('utf-8')}"

    req_malformed_json = b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 9\r\nContent-Type: application/json\r\n\r\n{invalid}"
    resp_malformed = send_raw_http(req_malformed_json)
    assert b"HTTP/1.1 400" in resp_malformed, f"Expected HTTP 400, got: {resp_malformed.decode('utf-8')}"

    req_get_msg = b"GET /message HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    resp_get_msg = send_raw_http(req_get_msg)
    assert b"HTTP/1.1 405" in resp_get_msg, f"Expected HTTP 405, got: {resp_get_msg.decode('utf-8')}"

    req_post_sse = b"POST /sse HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
    resp_post_sse = send_raw_http(req_post_sse)
    assert b"HTTP/1.1 405" in resp_post_sse, f"Expected HTTP 405, got: {resp_post_sse.decode('utf-8')}"

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mcp_sse_test_helper.py <port>")
        sys.exit(1)
    port = int(sys.argv[1])
    
    print("Running TASK 1 — SSE spec compliance...")
    test_sse_spec_compliance(port)
    print("ok - TASK 1 passed")
    
    print("Running TASK 2 — CORS & Token Auth...")
    test_cors_and_token_auth(port)
    print("ok - TASK 2 passed")
    
    print("Running TASK 3 — client_id validation...")
    test_client_id_validation(port)
    print("ok - TASK 3 passed")
    
    print("Running TASK 4 — Concurrency safety...")
    test_concurrency_safety(port)
    print("ok - TASK 4 passed")
    
    print("Running TASK 5 — Request robustness...")
    test_request_robustness(port)
    print("ok - TASK 5 passed")
    
    print("All helper tasks completed successfully.")

if __name__ == "__main__":
    main()
