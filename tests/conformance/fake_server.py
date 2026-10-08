import email.utils
import hashlib
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = "TestKey0123456789abcdefXYZ"


def fixture_bytes(name: str, seed: str = "v1", size: int = 200_000) -> bytes:
    body = hashlib.sha256((name + seed).encode()).digest() * (size // 32)
    if name.endswith(".mmdb"):
        return body + b"\xab\xcd\xefMaxMind.com" + b"\x00" * 64
    return body


class _File:
    def __init__(self, data: bytes):
        self.set(data)

    def set(self, data: bytes):
        self.data = data
        digest = hashlib.md5(data).hexdigest()
        self.etag = f"{digest}-{max(1, len(data) // (8 * 1024 * 1024) + 1)}"
        self.last_modified = email.utils.formatdate(time.time(), usegmt=True)


class FakeServer:
    def __init__(self):
        self.files: dict[str, _File] = {}
        self._lock = threading.Lock()
        self._fail: dict[str, int] = {}
        self._fail_auth: int | None = None
        self._stall: dict[str, float] = {}
        self._slow: dict[str, float] = {}
        self._change: dict[str, tuple[bytes, int]] = {}
        self._active = 0
        self.max_parallel = 0
        self.reset_stats()
        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        self.base = f"http://127.0.0.1:{self._httpd.server_port}"
        self.endpoint = f"{self.base}/auth"
        self.api_key = API_KEY

    def close(self):
        self._httpd.shutdown()

    def put(self, name: str, data: bytes):
        with self._lock:
            if name in self.files:
                self.files[name].set(data)
            else:
                self.files[name] = _File(data)

    def fail(self, name: str, status: int):
        self._fail[name] = status

    def fail_auth(self, status: int | None):
        self._fail_auth = status

    def stall(self, name: str, seconds: float):
        self._stall[name] = seconds

    def slow(self, name: str, seconds_total: float):
        self._slow[name] = seconds_total

    def change_during_download(self, name: str, new_data: bytes, after_bytes: int):
        self._change[name] = (new_data, after_bytes)

    def reset_stats(self):
        self._stats: dict[str, dict] = {}
        self.auth_attempts = 0
        self.max_parallel = 0

    def stats(self, name: str) -> dict:
        return self._stats.setdefault(name, {"attempts": 0, "full": 0, "prechecks": 0, "inm": 0, "not_modified": 0, "ranges": 0, "bytes": 0})

    def _handler(self):
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length)
                if self.path.rstrip("/") != "/auth":
                    return self._json(404, {"detail": "not found"})
                server.auth_attempts += 1
                if server._fail_auth is not None:
                    return self._json(server._fail_auth, {"detail": "injected"})
                if self.headers.get("X-API-Key") != API_KEY:
                    return self._json(401, {"detail": "Invalid API key"})
                try:
                    wanted = json.loads(raw or b"{}").get("databases", "all")
                except ValueError:
                    return self._json(400, {"detail": "bad json"})
                names = sorted(server.files) if wanted == "all" else list(wanted)
                unknown = [n for n in names if n not in server.files]
                if unknown:
                    return self._json(400, {"detail": f"Invalid database names: {unknown}"})
                return self._json(200, {n: f"{server.base}/s3/{n}?AWSAccessKeyId=x&Expires=9999999999&Signature=sig" for n in names})

            def do_GET(self):
                name = self.path.split("?")[0].removeprefix("/s3/")
                server.stats(name)["attempts"] += 1
                if name not in server.files:
                    return self._json(404, {"detail": "no such key"})
                if name in server._fail:
                    return self._json(server._fail[name], {"detail": "injected"})
                f = server.files[name]
                st = server.stats(name)
                rng = self.headers.get("Range")
                inm = (self.headers.get("If-None-Match") or "").strip().strip('"')
                ims = self.headers.get("If-Modified-Since")
                if rng == "bytes=0-0":
                    st["prechecks"] += 1
                if inm:
                    st["inm"] += 1
                if inm and inm == f.etag:
                    st["not_modified"] += 1
                    return self._empty(304, f)
                if ims and not inm:
                    try:
                        if email.utils.parsedate_to_datetime(ims) >= email.utils.parsedate_to_datetime(f.last_modified):
                            st["not_modified"] += 1
                            return self._empty(304, f)
                    except (TypeError, ValueError):
                        pass
                start, end = 0, len(f.data) - 1
                status = 200
                if rng and rng.startswith("bytes="):
                    a, _, b = rng[6:].partition("-")
                    start = int(a or 0)
                    end = int(b) if b else end
                    status = 206
                    st["ranges"] += 1
                if rng != "bytes=0-0" and start == 0:
                    st["full"] += 1
                with server._lock:
                    server._active += 1
                    server.max_parallel = max(server.max_parallel, server._active)
                try:
                    self._send_body(name, f, start, end, status)
                finally:
                    with server._lock:
                        server._active -= 1

            def _send_body(self, name, f, start, end, status):
                body = f.data[start:end + 1]
                self.send_response(status)
                self.send_header("ETag", f'"{f.etag}"')
                self.send_header("Last-Modified", f.last_modified)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(len(body)))
                if status == 206:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(f.data)}")
                self.end_headers()
                chunk = 16_384
                delay = server._slow.get(name, 0) / max(1, len(body) // chunk)
                change = server._change.pop(name, None) if len(body) > 1 else None
                sent = 0
                for i in range(0, len(body), chunk):
                    if change and sent >= change[1]:
                        server.put(name, change[0])
                        self.close_connection = True
                        return
                    self.wfile.write(body[i:i + chunk])
                    sent += len(body[i:i + chunk])
                    server.stats(name)["bytes"] += len(body[i:i + chunk])
                    if i == 0 and len(body) > chunk and name in server._stall:
                        self.wfile.flush()
                        time.sleep(server._stall[name])
                    if delay:
                        self.wfile.flush()
                        time.sleep(delay)

            def _empty(self, status, f):
                self.send_response(status)
                self.send_header("ETag", f'"{f.etag}"')
                self.send_header("Last-Modified", f.last_modified)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def _json(self, status, payload):
                data = json.dumps(payload, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return Handler
