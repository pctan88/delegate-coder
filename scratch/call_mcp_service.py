import urllib.request
import urllib.parse
import json

print("1. Connecting to SSE endpoint http://127.0.0.1:8001/sse...")
req = urllib.request.Request("http://127.0.0.1:8001/sse", method="GET")
with urllib.request.urlopen(req) as sse_stream:
    lines = []
    # Read handshake event lines
    for _ in range(4):
        line = sse_stream.readline().decode("utf-8").strip()
        if line:
            lines.append(line)
    
    print("Received SSE Handshake:", lines)
    # Extract endpoint path
    data_line = [l for l in lines if l.startswith("data: ")][0]
    post_path = data_line[len("data: "):]
    print(f"Parsed POST path: {post_path}")

# Construct JSON-RPC 2.0 tool call
request_payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
        "name": "delegate_contract",
        "arguments": {
            "target_file": "scratch/demo_app/todo_cli.py",
            "instructions": "Implement a command-line Todo app. It must parse arguments using argparse: --add (adds a todo task), --list (lists all tasks), and --delete (deletes a task by 1-based index). Tasks must be saved inside a JSON file named todo_db.json in the current working directory. Print details to stdout.",
            "test_command": "python3 scratch/demo_app/test_todo.py",
            "project_root": "/Users/pctan/Cowork/Workspace/AI/delegate-coder"
        }
    }
}

post_url = f"http://127.0.0.1:8001{post_path}"
print(f"2. Posting tools/call request to {post_url}...")
headers = {"Content-Type": "application/json"}
post_data = json.dumps(request_payload).encode("utf-8")

post_req = urllib.request.Request(post_url, data=post_data, headers=headers, method="POST")
try:
    with urllib.request.urlopen(post_req) as response:
        resp_data = response.read().decode("utf-8")
        resp_json = json.loads(resp_data)
        print("\n=== Response ===")
        print(json.dumps(resp_json, indent=2))
except Exception as e:
    print(f"Request failed: {e}")
