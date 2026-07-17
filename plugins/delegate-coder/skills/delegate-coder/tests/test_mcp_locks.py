#!/usr/bin/env python3
import sys
import os
import pathlib
import threading

# Add repository root to path so we can import mcp_server
repo_root = pathlib.Path(__file__).resolve().parents[5]
sys.path.insert(0, str(repo_root))

import mcp_server

def test_lock_timeout():
    # Set the timeout env var to 0 for instant timeout
    os.environ["MCP_BUSY_TIMEOUT"] = "0"
    
    project_path = str(repo_root.resolve())
    
    # Pre-acquire the lock for the repo root manually in-process
    with mcp_server.PROJECT_LOCKS_LOCK:
        if project_path not in mcp_server.PROJECT_LOCKS:
            mcp_server.PROJECT_LOCKS[project_path] = threading.Lock()
        lock = mcp_server.PROJECT_LOCKS[project_path]
    
    # Acquire the lock manually to block run_command
    lock.acquire()
    
    try:
        # Call run_command, which should immediately time out because busy_timeout=0
        rc, stdout, stderr = mcp_server.run_command(["true"], cwd=project_path)
        
        print(f"run_command result: rc={rc}, stdout={stdout}, stderr={stderr}")
        assert rc == 111, f"Expected exit code 111, got {rc}"
        assert stderr == "mcp_server: project is busy with another delegated task; retry later"
        print("ok - lock timeout test passed")
    finally:
        lock.release()

if __name__ == "__main__":
    test_lock_timeout()
