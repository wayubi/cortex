#!/usr/bin/env python3
"""Stand-in for llama-cpp, ollama and nllb, for tools/test_coordinator.py.

One process listens on 8080, 11434 and 5002; the test gives its container
the network aliases llama-cpp, ollama and nllb, so coordinator.lua's own
unload and status calls reach it exactly as they reach the real backends.
An inference sleeps for the `delay` its body names, so a test controls how
long a request stays in flight. No GPU, no model.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
LOADED = {"llama_cpp": None, "ollama": None, "nllb": None}
PORT_BACKEND = {8080: "llama_cpp", 11434: "ollama", 5002: "nllb"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _backend(self):
        return PORT_BACKEND[self.server.server_address[1]]

    def do_GET(self):
        b = self._backend()
        with LOCK:
            m = LOADED[b]
        if self.path == "/api/ps":
            return self._send({"models": [{"name": m}] if m else []})
        if self.path == "/v1/models":
            data = [{"id": m, "status": {"value": "loaded"}}] if m else []
            return self._send({"data": data})
        if self.path == "/slots":
            return self._send([])
        return self._send({"ok": True})

    def do_POST(self):
        b = self._backend()
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        if self.path in ("/models/unload", "/v1/models/unload") or (
                self.path == "/api/generate" and body.get("keep_alive") == 0):
            with LOCK:
                LOADED[b] = None
            return self._send({"ok": True})
        if self.path == "/shutdown":
            return self._send({"ok": True})
        with LOCK:
            LOADED[b] = body.get("model")
        time.sleep(float(body.get("delay", 0)))
        return self._send({"ok": True, "backend": b, "model": body.get("model")})


def main():
    servers = [ThreadingHTTPServer(("0.0.0.0", p), Handler) for p in PORT_BACKEND]
    for s in servers[1:]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
