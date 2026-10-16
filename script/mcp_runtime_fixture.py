#!/usr/bin/env python3
"""Fixtures for script/MCPRuntimeTests.swift.

stdio <record_dir>            MCP stdio server: tools `slow` (waits until cancelled, records the
                              cancellation) and `grow` (adds a tool and sends tools/list_changed).
                              Starts a background `sleep` (same process group) to prove the
                              Host terminates descendants.
token <record_dir>            Like stdio, but exits at once unless FIXTURE_TOKEN is set, as a
                              server that needs an access token does.
redirect <port_file> <record> HTTP server on two ports: the first answers every request with a 307
                              to the second, which records any request it receives.
"""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def stdio(record_dir):
    write_lock = threading.Lock()
    cancelled = threading.Event()
    tools = [{"name": "slow", "description": "Waits until cancelled", "inputSchema": {"type": "object"}},
             {"name": "grow", "description": "Adds a tool", "inputSchema": {"type": "object"}}]
    grandchild = subprocess.Popen(["/bin/sleep", "300"])
    with open(os.path.join(record_dir, "grandchild.pid"), "w") as f:
        f.write(str(grandchild.pid))

    def send(message):
        with write_lock:
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()

    def handle(message):
        method, request_id = message.get("method"), message.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "protocolVersion": message["params"]["protocolVersion"],
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": "limare-runtime-fixture", "version": "1"},
                "instructions": "Use the typed fixture tools; do not reach for scripts."}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": tools}})
        elif method == "tools/call" and message["params"]["name"] == "slow":
            def wait():
                if cancelled.wait(30):
                    open(os.path.join(record_dir, "cancelled"), "w").close()
                else:
                    send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "done"}]}})
            threading.Thread(target=wait, daemon=True).start()
        elif method == "tools/call" and message["params"]["name"] == "grow":
            tools.append({"name": "grown", "description": "Added at runtime", "inputSchema": {"type": "object"}})
            send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "grew"}]}})
            send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        elif method == "notifications/cancelled":
            cancelled.set()
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unknown"}})

    for line in sys.stdin:
        if line.strip():
            handle(json.loads(line))


def redirect(port_file, record):
    class Target(BaseHTTPRequestHandler):
        def do_POST(self):
            with open(record, "a") as f:
                f.write(json.dumps(dict(self.headers)) + "\n")
            self.send_response(500)
            self.end_headers()
        do_GET = do_POST

        def log_message(self, *args):
            pass

    target = ThreadingHTTPServer(("127.0.0.1", 0), Target)

    class Redirector(BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(307)
            self.send_header("Location", "http://127.0.0.1:%d/mcp" % target.server_address[1])
            self.end_headers()
        do_GET = do_POST

        def log_message(self, *args):
            pass

    redirector = ThreadingHTTPServer(("127.0.0.1", 0), Redirector)
    threading.Thread(target=target.serve_forever, daemon=True).start()
    with open(port_file, "w") as f:
        f.write(str(redirector.server_address[1]))
    redirector.serve_forever()


if __name__ == "__main__":
    if sys.argv[1] == "stdio":
        stdio(sys.argv[2])
    elif sys.argv[1] == "token":
        if os.environ.get("FIXTURE_TOKEN") != "synthetic-fixture-token":
            sys.stderr.write("FIXTURE_TOKEN is not set\n")
            sys.exit(1)
        stdio(sys.argv[2])
    else:
        redirect(sys.argv[2], sys.argv[3])
