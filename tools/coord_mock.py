#!/usr/bin/env python3
"""Stand-in for the llama.cpp routers, ollama and nllb, for tools/test_coordinator.py.

One process listens on 8080, 11434 and 5002; the test gives its container
the network aliases llama-cpp, ollama and nllb, so coordinator.lua's own
unload and status calls reach it exactly as they reach the real backends.
More containers (MOCK_8080=prism_llama_cpp / raon_llama_cpp /
inkling_llama_cpp, aliased by host) stand
in for the other :8080 routers; replies name the backend that answered.
An inference sleeps for the `delay` its body names, so a test controls how
long a request stays in flight. No GPU, no model.

Slot cache: POST /slots/0?action=save|restore (model and filename in the JSON
body, as the real router takes them) keeps a set of saved filenames; a
restore of an unknown one answers 400. POST /models/load loads a model.
GET /__log returns every load, unload, save, restore and inference in order;
POST /__control {"save_fail": bool, "save_delay": s, "load_delay": s} shapes the
next saves and loads (a delayed load is not listed until it completes);
POST /__reset clears the log, the saved files and the controls.
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
NAME_8080 = os.environ.get("MOCK_8080", "llama_cpp")
LOADED = {NAME_8080: None, "ollama": None, "nllb": None}
PORT_BACKEND = {8080: NAME_8080, 11434: "ollama", 5002: "nllb"}
LOG = []          # (t, backend, event, model)
FILES = set()     # saved slot filenames
CONTROL = {"save_fail": False, "save_delay": 0.0, "load_delay": 0.0}


def note(b, event, model):
    with LOCK:
        LOG.append((round(time.time(), 3), b, event, model))


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

    def _send_chunked(self, obj, status=200):
        """As llama.cpp answers /slots: Transfer-Encoding: chunked."""
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        half = len(body) // 2
        for part in (body[:half], body[half:]):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
        self.wfile.write(b"0\r\n\r\n")

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
        if self.path == "/__log":
            with LOCK:
                return self._send(list(LOG))
        return self._send({"ok": True, "backend": b})

    def do_POST(self):
        b = self._backend()
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        if self.path == "/__control":
            with LOCK:
                CONTROL.update(body)
            return self._send({"ok": True})
        if self.path == "/__reset":
            with LOCK:
                LOG.clear(); FILES.clear()
                CONTROL.update(save_fail=False, save_delay=0.0, load_delay=0.0)
            return self._send({"ok": True})
        if self.path.startswith("/slots/0?action="):
            action = self.path.split("=", 1)[1]
            model, fname = body.get("model"), body.get("filename")
            if not model:
                return self._send({"error": {"code": 400, "message": "model name is missing from the request"}}, 400)
            if action == "save":
                time.sleep(float(CONTROL["save_delay"]))
                if CONTROL["save_fail"]:
                    note(b, "save-failed", model)
                    return self._send({"error": {"code": 500, "message": "save failed"}}, 500)
                with LOCK:
                    FILES.add(fname)
                note(b, "save", model)
                return self._send_chunked({"id_slot": 0, "filename": fname, "n_saved": 1234, "n_written": 5678})
            if action == "restore":
                with LOCK:
                    known = fname in FILES
                if not known:
                    note(b, "restore-missing", model)
                    return self._send_chunked({"error": {"code": 400, "message": "failed to open slot file"}}, 400)
                note(b, "restore", model)
                return self._send_chunked({"id_slot": 0, "filename": fname, "n_restored": 1234, "n_read": 5678})
            return self._send({"error": "unknown action"}, 400)
        if self.path == "/models/load":
            model = body.get("model")
            note(b, "load", model)

            def done():
                with LOCK:
                    LOADED[b] = model
                note(b, "loaded", model)
            delay = float(CONTROL["load_delay"])
            if delay > 0:
                threading.Timer(delay, done).start()
            else:
                done()
            return self._send({"success": True})
        if self.path in ("/models/unload", "/v1/models/unload") or (
                self.path == "/api/generate" and body.get("keep_alive") == 0):
            with LOCK:
                gone = LOADED[b]
                LOADED[b] = None
            note(b, "unload", gone)
            return self._send({"ok": True})
        if self.path == "/shutdown":
            return self._send({"ok": True})
        with LOCK:
            LOADED[b] = body.get("model")
        note(b, "infer", body.get("model"))
        time.sleep(float(body.get("delay", 0)))
        return self._send({"ok": True, "backend": b, "model": body.get("model")})


def main():
    servers = [ThreadingHTTPServer(("0.0.0.0", p), Handler) for p in PORT_BACKEND]
    for s in servers[1:]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
