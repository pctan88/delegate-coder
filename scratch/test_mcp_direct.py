import urllib.request
import urllib.parse
import json

base_url = "http://127.0.0.1:8001"

print("--- Testing SSE Connection ---")
req = urllib.request.Request(f"{base_url}/sse", method="GET")
with urllib.request.urlopen(req) as stream:
    lines = [stream.readline().decode('utf-8').strip() for _ in range(3)]
    print("SSE Handshake Response:")
    for line in lines:
        if line:
            print(f"  {line}")
    data_line = [l for l in lines if l.startswith("data: ")][0]
    post_path = data_line[len("data: "):]
    print(f"Post Endpoint: {post_path}\n")

post_url = f"{base_url}{post_path}"

def send_post(method, params, req_id):
    payload = {
        "jsonrpc": "2.0",
        "id": req_id,
        "method": method,
        "params": params
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(post_url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as res:
        return json.loads(res.read().decode("utf-8"))

print("--- Testing initialize Handshake ---")
init_res = send_post("initialize", {"protocolVersion": "2024-11-05"}, 1)
print(json.dumps(init_res, indent=2))
print()

print("--- Testing tools/list Discovery ---")
list_res = send_post("tools/list", {}, 2)
print("Available tools:")
for t in list_res.get("result", {}).get("tools", []):
    print(f"  - {t['name']}: {t['description']}")
print()

print("--- Testing tools/call (delegate_doctor) ---")
doctor_res = send_post("tools/call", {"name": "delegate_doctor", "arguments": {"all": False}}, 3)
print(json.dumps(doctor_res, indent=2))
