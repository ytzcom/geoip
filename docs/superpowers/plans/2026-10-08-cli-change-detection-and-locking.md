# CLI Change Detection, Shared-Path Locking and Consistency — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give all seven GeoIP clients the same opt-in `--only-changed`/`--force`/`--lock-file`/`--lock-timeout`, atomic `.part` staging and unified environment variables, behind a black-box conformance suite that proves default behaviour is unchanged — released as v1.2.0.

**Architecture:** A pytest conformance suite (`tests/conformance/`) runs every client as a subprocess against a local fake server that reproduces the probed production behaviour (S3-style pre-signed URLs, multipart ETags, `304` on `If-None-Match`, ranges, `HEAD` → `403`). The suite runs in one Docker image (local and CI identical). Baseline tests are written and pass against the unchanged clients first; then each client is changed until the new-behaviour tests pass. Change detection uses a small "pre-check" request (`Range: bytes=0-0`, optionally with `If-None-Match`) before and after each download, so every client's existing download/resume loop stays untouched.

**Tech Stack:** POSIX sh (dash, BusyBox), bash, Python 3 (click, aiohttp), Go (stdlib only), PowerShell (pwsh), pytest, Docker, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-08-cli-change-detection-and-locking-design.md`

## Global Constraints

- No breaking changes: with no new option or new environment variable set, every client's results, exit codes and files on disk are as today. Allowed default-visible changes: a transient `<name>.part` in the target directory during downloads; newly honoured env vars take effect when set.
- Option names: `--only-changed`, `--force`, `--lock-file PATH`, `--lock-timeout SECONDS` (PowerShell: `-OnlyChanged`, `-Force`, `-LockFile`, `-LockTimeout`). Long forms only. Env: `GEOIP_ONLY_CHANGED` (`true`/`1`/`yes`), `GEOIP_LOCK_FILE`, `GEOIP_LOCK_TIMEOUT`. YAML keys (POSIX, Python): `only_changed`, `lock_file`, `lock_timeout`.
- `--lock-timeout` default `1800`. Timeout message: `Timed out after N s waiting for lock PATH`, exit 1. `--lock-file` + `--no-lock` → exit 1 with `--lock-file and --no-lock cannot be combined`.
- Manifest: `<target>/.geoip-update.json`, canonical layout exactly as in the spec (2-space indent, `version` then `files`, one entry per line sorted by name, keys `etag`, `last_modified`, `size`, ETag without outer quotes). Entries whose values contain `"`, `\` or control characters are not recorded. Written once at end of run via `.geoip-update.json.part` + rename. Unparseable manifest = absent.
- Unchanged log line: `Unchanged: <name>`.
- Unified env vars honoured by every client as flag defaults: `GEOIP_API_KEY`, `GEOIP_API_ENDPOINT`, `GEOIP_TARGET_DIR`, `GEOIP_DATABASES`, `GEOIP_CONCURRENT`, `GEOIP_LOG_FILE`, `GEOIP_TIMEOUT`, `GEOIP_MAX_RETRIES`. Flags win. Precedence otherwise per each client's existing order.
- Shell fallback lock: `mkdir "$LOCK_FILE.d"`, stale after download ceiling (`--timeout`, default 1800) + 300 s; test-only hooks `GEOIP_LOCK_FORCE_FALLBACK=1` and `GEOIP_LOCK_STALE_SECONDS` (not in user docs).
- Exit codes unchanged: PowerShell `2` for partial download failure, others `1`.
- No new runtime dependencies; Go stays stdlib-only; POSIX script runs under dash and BusyBox `sh`.
- Version `1.2.0` (`2.1.0-posix` for the POSIX script's own string).
- Do not modify `.serena/project.yml`. Do not push. Comments minimal: no narration of history or fixes.
- STOP on the first unexpected failure (including a client whose baseline cannot run in the test image): report the literal command and output, do not work around it.

## Review Focus

- A client that was fine by default must stay byte-identical by default: the baseline suite must pass unchanged after every client task (re-run it in every task, not only the client's new tests).
- `kill -9` of a lock holder must never block later runs, for every client, including the shell fallback past its stale threshold.
- A manifest written by any client must be read by every other client (cross-client compatibility), including the POSIX reader that has no JSON parser.
- `304` handling in PowerShell 5.1-style code paths: `Invoke-WebRequest` treats non-2xx as an exception; the pre-check must read the status from the exception, not crash.
- A target directory where a previous run was killed mid-download (stale `<name>.part`) must still end with complete files.

---

### Task 1: Conformance harness, baseline tests, test image, CI, symlink fix

**Files:**
- Restore: `cli/python-cron/geoip-update.py`, `cli/python-cron/requirements.txt`, `cli/python-k8s/geoip-update.py`, `cli/python-k8s/requirements.txt` (symlinks)
- Create: `tests/conformance/fake_server.py`, `tests/conformance/clients.py`, `tests/conformance/conftest.py`, `tests/conformance/test_baseline.py`, `tests/conformance/test_symlinks.py`, `tests/conformance/requirements.txt`, `tests/conformance/Dockerfile`, `tests/conformance/run.sh`
- Create: `.github/workflows/tests.yml`

**Interfaces:**
- Produces (used by every later task):
  - `fake_server.FakeServer` with `.endpoint` (full `/auth` URL), `.api_key`, `.put(name, data)`, `.stats(name) -> dict` (`full`, `prechecks`, `not_modified`, `ranges`, `bytes`), `.fail(name, status)`, `.slow(name, seconds_total)`, `.change_during_download(name, new_data, after_bytes)`, `.max_parallel` (peak concurrent GETs), `.reset_stats()`.
  - `clients.CLIENTS` (ids: `posix-dash`, `posix-busybox`, `bash`, `python`, `go`, `powershell`), `clients.run(client, server, target, *, databases, extra=(), env=None, timeout=120) -> subprocess.CompletedProcess`, `clients.start(...) -> subprocess.Popen` (same args, non-blocking), `clients.flag(client, canonical) -> list[str]` mapping canonical options to the client's syntax.
  - Fixtures in `conftest.py`: `server` (fresh `FakeServer` per test with `GeoIP2-City.mmdb` and `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN` loaded), `target` (fresh temp dir), `client` (parametrized over `CLIENTS`), `go_binary` (session-scoped `go build`).

- [ ] **Step 1: Restore the symlinks**

```bash
git checkout -- cli/python-cron/geoip-update.py cli/python-cron/requirements.txt cli/python-k8s/geoip-update.py cli/python-k8s/requirements.txt
ls -l cli/python-cron/geoip-update.py cli/python-k8s/requirements.txt
```
Expected: both point at `../python/...`. `git status --short` shows only `.serena/project.yml` modified (leave it).

- [ ] **Step 2: Write `tests/conformance/fake_server.py`**

```python
import email.utils
import hashlib
import json
import os
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

    def slow(self, name: str, seconds_total: float):
        self._slow[name] = seconds_total

    def change_during_download(self, name: str, new_data: bytes, after_bytes: int):
        self._change[name] = (new_data, after_bytes)

    def reset_stats(self):
        self._stats: dict[str, dict] = {}
        self.max_parallel = 0

    def stats(self, name: str) -> dict:
        return self._stats.setdefault(name, {"full": 0, "prechecks": 0, "not_modified": 0, "ranges": 0, "bytes": 0})

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
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return Handler
```

- [ ] **Step 3: Write `tests/conformance/clients.py`**

The `_FLAGS` table maps canonical options to each client's existing syntax. Verify every existing flag against the client's parser before relying on it (`--help` of each client); correct only this table if a mapping is wrong. A `None` entry means the client has no such option (tests needing it are skipped for that client).

```python
import os
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CLIENTS = ["posix-dash", "posix-busybox", "bash", "python", "go", "powershell"]
GO_BINARY = Path(os.environ.get("GEOIP_TEST_GO_BINARY", "/tmp/geoip-update-go"))

_BASE = {
    "posix-dash": ["dash", str(REPO / "cli/geoip-update-posix.sh")],
    "posix-busybox": ["busybox", "sh", str(REPO / "cli/geoip-update-posix.sh")],
    "bash": ["bash", str(REPO / "cli/geoip-update.sh")],
    "python": ["python3", str(REPO / "cli/python/geoip-update.py")],
    "go": [str(GO_BINARY)],
    "powershell": ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(REPO / "cli/geoip-update.ps1")],
}

_FLAGS = {
    "api_key":      {"posix": "--api-key", "bash": "--api-key", "python": "--api-key", "go": "--api-key", "powershell": "-ApiKey"},
    "endpoint":     {"posix": "--endpoint", "bash": "--endpoint", "python": "--endpoint", "go": "--endpoint", "powershell": "-ApiEndpoint"},
    "directory":    {"posix": "--directory", "bash": "--directory", "python": "--directory", "go": "--directory", "powershell": "-TargetDirectory"},
    "databases":    {"posix": "--databases", "bash": "--databases", "python": "--databases", "go": "--databases", "powershell": "-Databases"},
    "max_retries":  {"posix": "--max-retries", "bash": "--retries", "python": "--retries", "go": "--retries", "powershell": "-MaxRetries"},
    "timeout":      {"posix": "--timeout", "bash": "--timeout", "python": "--timeout", "go": "--timeout", "powershell": "-Timeout"},
    "log_file":     {"posix": "--log-file", "bash": "--log-file", "python": "--log-file", "go": "--log-file", "powershell": "-LogFile"},
    "concurrent":   {"posix": None, "bash": None, "python": "--concurrent", "go": "--concurrent", "powershell": None},
    "no_lock":      {"posix": None, "bash": "--no-lock", "python": "--no-lock", "go": "--no-lock", "powershell": "-NoLock"},
    "only_changed": {"posix": "--only-changed", "bash": "--only-changed", "python": "--only-changed", "go": "--only-changed", "powershell": "-OnlyChanged"},
    "force":        {"posix": "--force", "bash": "--force", "python": "--force", "go": "--force", "powershell": "-Force"},
    "lock_file":    {"posix": "--lock-file", "bash": "--lock-file", "python": "--lock-file", "go": "--lock-file", "powershell": "-LockFile"},
    "lock_timeout": {"posix": "--lock-timeout", "bash": "--lock-timeout", "python": "--lock-timeout", "go": "--lock-timeout", "powershell": "-LockTimeout"},
}

_SWITCHES = {"no_lock", "only_changed", "force"}


def family(client: str) -> str:
    return "posix" if client.startswith("posix") else client


def flag(client: str, canonical: str, value=None) -> list[str]:
    name = _FLAGS[canonical][family(client)]
    if name is None:
        raise LookupError(f"{client} has no {canonical}")
    if canonical in _SWITCHES:
        return [name]
    if canonical == "databases":
        if family(client) == "python":
            return [x for db in value for x in (name, db)]
        return [name, ",".join(value)]
    return [name, str(value)]


def command(client, server, target, databases, extra=()) -> list[str]:
    cmd = list(_BASE[client])
    cmd += flag(client, "api_key", server.api_key)
    cmd += flag(client, "endpoint", server.endpoint)
    cmd += flag(client, "directory", target)
    if databases is not None:
        cmd += flag(client, "databases", databases)
    for item in extra:
        cmd += flag(client, *item) if isinstance(item, tuple) else flag(client, item)
    return cmd


def _env(env):
    base = {k: v for k, v in os.environ.items() if not k.startswith("GEOIP_")}
    base.update(env or {})
    return base


def run(client, server, target, *, databases=("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"), extra=(), env=None, timeout=120, bare=False):
    cmd = list(_BASE[client]) if bare else command(client, server, target, databases, extra)
    return subprocess.run(cmd, capture_output=True, text=True, env=_env(env), timeout=timeout)


def start(client, server, target, *, databases=("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"), extra=(), env=None):
    return subprocess.Popen(command(client, server, target, databases, extra), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=_env(env))


def available(client: str) -> bool:
    exe = {"posix-dash": "dash", "posix-busybox": "busybox", "bash": "bash", "python": "python3", "go": str(GO_BINARY), "powershell": "pwsh"}[client]
    return shutil.which(exe) is not None or Path(exe).exists()
```

- [ ] **Step 4: Write `tests/conformance/conftest.py`**

```python
import subprocess
from pathlib import Path

import pytest

from clients import CLIENTS, GO_BINARY, REPO, available
from fake_server import FakeServer, fixture_bytes

DBS = ("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")


@pytest.fixture(scope="session", autouse=True)
def go_binary():
    subprocess.run(["go", "build", "-o", str(GO_BINARY), "."], cwd=REPO / "cli/go", check=True)
    return GO_BINARY


@pytest.fixture
def server():
    s = FakeServer()
    for name in DBS:
        s.put(name, fixture_bytes(name))
    yield s
    s.close()


@pytest.fixture
def target(tmp_path) -> Path:
    d = tmp_path / "geoip"
    d.mkdir()
    return d


@pytest.fixture(params=CLIENTS)
def client(request):
    if not available(request.param):
        pytest.fail(f"{request.param} is not installed in the test image")
    return request.param
```

- [ ] **Step 5: Write `tests/conformance/test_baseline.py`**

These pin today's behaviour. The lock test is a characterization: first run `pytest tests/conformance/test_baseline.py -k default_lock -s` against the unchanged clients, read what each client actually does when a second run starts while the first holds its default lock, then encode exactly that per client in `EXPECTED_SECOND_RUN` (`"succeeds"` or `"fails"`). Record the observed outputs in the task report.

```python
import time

import pytest

from clients import run, start, flag
from conftest import DBS
from fake_server import fixture_bytes

EXPECTED_SECOND_RUN = {
    "posix-dash": "succeeds",
    "posix-busybox": "succeeds",
    "bash": "fails",
    "python": "fails",
    "go": "fails",
    "powershell": "fails",
}


def test_default_run_downloads_every_requested_file(client, server, target):
    result = run(client, server, target)
    assert result.returncode == 0, result.stdout + result.stderr
    for name in DBS:
        assert (target / name).read_bytes() == fixture_bytes(name)


def test_default_run_leaves_no_manifest_and_no_part_files(client, server, target):
    run(client, server, target)
    leftovers = sorted(p.name for p in target.iterdir() if p.name not in DBS)
    assert leftovers == []


def test_partial_failure_keeps_successes_with_todays_exit_code(client, server, target):
    server.fail("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN", 500)
    result = run(client, server, target, extra=[("max_retries", 1)])
    assert result.returncode == (2 if client == "powershell" else 1), result.stdout + result.stderr
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
    assert not (target / "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN").exists()


def test_default_lock_behaviour_is_unchanged(client, server, target):
    server.slow("GeoIP2-City.mmdb", 6)
    first = start(client, server, target)
    time.sleep(2)
    second = run(client, server, target)
    first.wait(timeout=120)
    outcome = "succeeds" if second.returncode == 0 else "fails"
    assert outcome == EXPECTED_SECOND_RUN[client], second.stdout + second.stderr
```

If the observed behaviour for a client is neither a clean success nor a clean failure (e.g. it hangs past the 120 s timeout), STOP and report it.

- [ ] **Step 6: Write `tests/conformance/test_symlinks.py`**

```python
from clients import REPO


def test_cron_and_k8s_use_the_python_client():
    for flavour in ("python-cron", "python-k8s"):
        for name in ("geoip-update.py", "requirements.txt"):
            link = REPO / "cli" / flavour / name
            assert link.is_symlink(), link
            assert link.resolve() == (REPO / "cli/python" / name).resolve(), link
```

- [ ] **Step 7: Test image, runner, CI**

`tests/conformance/requirements.txt` — pin the current latest `pytest` release (check PyPI at implementation time and write the exact version):
```
pytest==<latest>
```

`tests/conformance/Dockerfile` (verify the base image tag and the `golang` tag exist on Docker Hub / MCR at implementation time; use the newest available that matches):
```dockerfile
FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash dash busybox curl python3 python3-pip util-linux ca-certificates hostname \
 && rm -rf /var/lib/apt/lists/*
COPY --from=golang:1.26 /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod
COPY cli/python/requirements.txt /tmp/req/client.txt
COPY tests/conformance/requirements.txt /tmp/req/tests.txt
RUN pip3 install --no-cache-dir -r /tmp/req/client.txt -r /tmp/req/tests.txt
WORKDIR /repo
COPY . .
CMD ["sh", "-c", "cd tests/conformance && python3 -m pytest -q -p no:cacheprovider \"$@\" && cd /repo/cli/go && go test ./...", "--"]
```

`tests/conformance/run.sh`:
```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
docker build -q -f tests/conformance/Dockerfile -t geoip-conformance . >/dev/null
exec docker run --rm geoip-conformance sh -c "cd tests/conformance && python3 -m pytest -q -p no:cacheprovider $* && cd /repo/cli/go && go test ./..."
```
`chmod +x tests/conformance/run.sh`.

`.github/workflows/tests.yml`:
```yaml
name: Tests

on:
  push:
    branches: [main]
  pull_request:

jobs:
  conformance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Conformance suite and Go tests
        run: tests/conformance/run.sh
```
(Check `actions/checkout`'s current major and use it.)

- [ ] **Step 8: Run the baseline**

Run: `tests/conformance/run.sh -x`
Expected: every baseline and symlink test passes against the unchanged clients, and `go test ./...` passes. If any client cannot run in the image (missing interpreter feature, a client that fails its own baseline), STOP and report the literal output — do not change client code in this task.

- [ ] **Step 9: Commit**

```bash
git add cli/python-cron/geoip-update.py cli/python-cron/requirements.txt cli/python-k8s/geoip-update.py cli/python-k8s/requirements.txt tests/conformance .github/workflows/tests.yml
git commit -m "test: conformance suite pinning current client behaviour; restore cron/k8s symlinks"
```

---

### Task 2: New-behaviour tests (red)

**Files:**
- Create: `tests/conformance/test_only_changed.py`, `tests/conformance/test_locking.py`, `tests/conformance/test_staging.py`, `tests/conformance/test_env.py`, `tests/conformance/manifest.py`

**Interfaces:**
- Consumes: Task 1 fixtures and helpers.
- Produces: `manifest.canonical(entries: dict[str, dict]) -> str`, `manifest.read(path) -> dict[str, dict]`; the red suites every client task turns green with `-k <client>`.

- [ ] **Step 1: `tests/conformance/manifest.py`**

```python
import json
from pathlib import Path


def canonical(entries: dict) -> str:
    lines = ["{", '  "version": 1,', '  "files": {']
    names = sorted(entries)
    for i, name in enumerate(names):
        e = entries[name]
        comma = "," if i < len(names) - 1 else ""
        lines.append(f'    "{name}": {{"etag": "{e["etag"]}", "last_modified": "{e["last_modified"]}", "size": {e["size"]}}}{comma}')
    lines += ["  }", "}"]
    return "\n".join(lines) + "\n"


def read(path: Path) -> dict:
    return json.loads(path.read_text())["files"]
```

- [ ] **Step 2: `tests/conformance/test_only_changed.py`**

```python
from clients import run
from conftest import DBS
from fake_server import fixture_bytes
import manifest

M = ".geoip-update.json"


def _ok(result):
    assert result.returncode == 0, result.stdout + result.stderr


def test_first_run_downloads_and_writes_the_canonical_manifest(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    text = (target / M).read_text()
    expected = {n: {"etag": server.files[n].etag, "last_modified": server.files[n].last_modified, "size": len(server.files[n].data)} for n in DBS}
    assert text == manifest.canonical(expected)
    for n in DBS:
        assert (target / n).read_bytes() == fixture_bytes(n)


def test_second_run_downloads_nothing_and_logs_unchanged(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    server.reset_stats()
    result = run(client, server, target, extra=["only_changed"])
    _ok(result)
    for n in DBS:
        assert server.stats(n)["full"] == 0
        assert server.stats(n)["not_modified"] == 1
        assert f"Unchanged: {n}" in result.stdout + result.stderr


def test_only_the_changed_file_downloads(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    server.put("GeoIP2-City.mmdb", fixture_bytes("GeoIP2-City.mmdb", "v2"))
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed"]))
    assert server.stats("GeoIP2-City.mmdb")["full"] == 1
    assert server.stats("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")["full"] == 0
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb", "v2")
    assert manifest.read(target / M)["GeoIP2-City.mmdb"]["etag"] == server.files["GeoIP2-City.mmdb"].etag


def test_wrong_size_or_missing_file_downloads_again(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    (target / "GeoIP2-City.mmdb").write_bytes(b"truncated")
    (target / "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN").unlink()
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed"]))
    for n in DBS:
        assert server.stats(n)["full"] == 1
        assert (target / n).read_bytes() == fixture_bytes(n)


def test_force_downloads_everything(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed", "force"]))
    for n in DBS:
        assert server.stats(n)["full"] == 1


def test_corrupt_manifest_is_treated_as_absent(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    (target / M).write_text("{ not json")
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed"]))
    for n in DBS:
        assert server.stats(n)["full"] == 1
    assert set(manifest.read(target / M)) == set(DBS)


def test_object_changing_mid_download_restarts_the_file(client, server, target):
    new = fixture_bytes("GeoIP2-City.mmdb", "v3")
    server.change_during_download("GeoIP2-City.mmdb", new, after_bytes=50_000)
    _ok(run(client, server, target, extra=["only_changed"]))
    assert (target / "GeoIP2-City.mmdb").read_bytes() == new
    assert manifest.read(target / M)["GeoIP2-City.mmdb"]["etag"] == server.files["GeoIP2-City.mmdb"].etag


def test_entries_for_unrequested_files_are_kept(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    _ok(run(client, server, target, databases=["GeoIP2-City.mmdb"], extra=["only_changed"]))
    assert set(manifest.read(target / M)) == set(DBS)


def test_stale_part_file_still_ends_with_a_complete_file(client, server, target):
    (target / "GeoIP2-City.mmdb.part").write_bytes(b"garbage from a killed run")
    _ok(run(client, server, target, extra=["only_changed"]))
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
```

- [ ] **Step 3: `tests/conformance/test_locking.py`**

```python
import os
import signal
import time

import pytest

from clients import run, start


def _lock(target):
    return str(target / ".geoip-update.lock")


def test_second_run_waits_then_finds_everything_unchanged(client, server, target):
    server.slow("GeoIP2-City.mmdb", 6)
    extra = ["only_changed", ("lock_file", _lock(target))]
    first = start(client, server, target, extra=extra)
    time.sleep(2)
    server_full_before = server.stats("GeoIP2-City.mmdb")["full"]
    second = run(client, server, target, extra=extra)
    assert first.wait(timeout=120) == 0
    assert second.returncode == 0, second.stdout + second.stderr
    assert server.stats("GeoIP2-City.mmdb")["full"] == server_full_before
    assert "Unchanged: GeoIP2-City.mmdb" in second.stdout + second.stderr


def test_lock_timeout_exits_1_with_message(client, server, target):
    server.slow("GeoIP2-City.mmdb", 8)
    first = start(client, server, target, extra=[("lock_file", _lock(target))])
    time.sleep(2)
    second = run(client, server, target, extra=[("lock_file", _lock(target)), ("lock_timeout", 1)])
    first.wait(timeout=120)
    assert second.returncode == 1
    assert f"Timed out after 1 s waiting for lock {_lock(target)}" in second.stdout + second.stderr


@pytest.mark.parametrize("fallback", [False, True])
def test_killed_holder_never_blocks_the_next_run(client, server, target, fallback):
    if fallback and not (client.startswith("posix") or client == "bash"):
        pytest.skip("the mkdir fallback exists only in the shell clients")
    env = {"GEOIP_LOCK_FORCE_FALLBACK": "1", "GEOIP_LOCK_STALE_SECONDS": "5"} if fallback else None
    server.slow("GeoIP2-City.mmdb", 30)
    extra = [("lock_file", _lock(target))]
    first = start(client, server, target, extra=extra, env=env)
    time.sleep(3)
    first.send_signal(signal.SIGKILL)
    first.wait(timeout=30)
    server.slow("GeoIP2-City.mmdb", 0)
    began = time.time()
    second = run(client, server, target, extra=extra + [("lock_timeout", 60)], env=env)
    assert second.returncode == 0, second.stdout + second.stderr
    assert time.time() - began < 30


def test_lock_file_with_no_lock_is_rejected(client, server, target):
    if client.startswith("posix"):
        pytest.skip("the POSIX client has no --no-lock")
    result = run(client, server, target, extra=[("lock_file", _lock(target)), "no_lock"])
    assert result.returncode == 1
    assert "--lock-file and --no-lock cannot be combined" in result.stdout + result.stderr
```

For PowerShell, `pwsh` is the process; SIGKILL to it is the intended "crash". The fallback case shortens the stale threshold with the test-only `GEOIP_LOCK_STALE_SECONDS=5`.

- [ ] **Step 4: `tests/conformance/test_staging.py`**

```python
import threading
import time

from clients import start
from fake_server import fixture_bytes


def test_target_name_is_never_a_partial_file(client, server, target):
    old = fixture_bytes("GeoIP2-City.mmdb", "old")
    (target / "GeoIP2-City.mmdb").write_bytes(old)
    server.slow("GeoIP2-City.mmdb", 5)
    seen = set()
    stop = threading.Event()

    def watch():
        while not stop.is_set():
            p = target / "GeoIP2-City.mmdb"
            if p.exists():
                data = p.read_bytes()
                seen.add("old" if data == old else "new" if data == fixture_bytes("GeoIP2-City.mmdb") else "partial")
            time.sleep(0.05)

    t = threading.Thread(target=watch)
    t.start()
    proc = start(client, server, target, extra=[] if client.startswith("posix") else ["no_lock"])
    proc.wait(timeout=120)
    stop.set()
    t.join()
    assert "partial" not in seen
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
```

- [ ] **Step 5: `tests/conformance/test_env.py`**

Each variable must behave exactly like its flag.

```python
import pytest

from clients import run
from conftest import DBS


def test_databases_from_env(client, server, target):
    result = run(client, server, target, databases=None, env={"GEOIP_DATABASES": "GeoIP2-City.mmdb"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert sorted(p.name for p in target.iterdir()) == ["GeoIP2-City.mmdb"]


def test_connection_settings_from_env(client, server, target):
    env = {
        "GEOIP_API_KEY": server.api_key,
        "GEOIP_API_ENDPOINT": server.endpoint,
        "GEOIP_TARGET_DIR": str(target),
        "GEOIP_DATABASES": ",".join(DBS),
    }
    result = run(client, server, target, env=env, bare=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert sorted(p.name for p in target.iterdir()) == sorted(DBS)


def test_log_file_from_env(client, server, target, tmp_path):
    log = tmp_path / "update.log"
    assert run(client, server, target, env={"GEOIP_LOG_FILE": str(log)}).returncode == 0
    assert log.exists() and log.stat().st_size > 0


def test_max_retries_from_env_matches_the_flag(client, server, target, tmp_path):
    server.fail("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN", 500)
    run(client, server, target, extra=[("max_retries", 2)])
    by_flag = server.stats("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")
    server.reset_stats()
    (tmp_path / "b").mkdir()
    run(client, server, tmp_path / "b", env={"GEOIP_MAX_RETRIES": "2"})
    assert server.stats("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN") == by_flag


def test_concurrency_from_env(client, server, target):
    server.slow("GeoIP2-City.mmdb", 2)
    server.slow("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN", 2)
    assert run(client, server, target, env={"GEOIP_CONCURRENT": "1"}).returncode == 0
    assert server.max_parallel == 1


def test_timeout_from_env_matches_the_flag(client, server, target, tmp_path):
    server.slow("GeoIP2-City.mmdb", 20)
    by_flag = run(client, server, target, extra=[("timeout", 2)]).returncode
    (tmp_path / "b").mkdir()
    by_env = run(client, server, tmp_path / "b", env={"GEOIP_TIMEOUT": "2"}).returncode
    assert by_env == by_flag


@pytest.mark.parametrize("value", ["true", "1", "yes"])
def test_only_changed_and_lock_from_env(client, server, target, value):
    env = {"GEOIP_ONLY_CHANGED": value, "GEOIP_LOCK_FILE": str(target / ".geoip-update.lock"), "GEOIP_LOCK_TIMEOUT": "60"}
    assert run(client, server, target, env=env).returncode == 0
    server.reset_stats()
    assert run(client, server, target, env=env).returncode == 0
    for n in DBS:
        assert server.stats(n)["full"] == 0
```

- [ ] **Step 6: Run the new suites, confirm red, commit**

Run: `tests/conformance/run.sh tests/conformance/test_only_changed.py tests/conformance/test_locking.py tests/conformance/test_staging.py tests/conformance/test_env.py`
Expected: new-behaviour tests FAIL for clients missing the feature (unknown option errors, missing manifest). `test_staging.py` already passes for the POSIX clients; record which pass today in the report. The baseline suite must still pass.

```bash
git add tests/conformance
git commit -m "test: conformance cases for change detection, shared-path locking, atomic staging and env vars"
```

---

### Task 3: POSIX client (`cli/geoip-update-posix.sh`)

**Files:** Modify `cli/geoip-update-posix.sh` (parser L154-222, `load_config` L229-270, `download_database` ~L490-600, `download_all` L612-690, `main` ~L1100-1158, defaults L33-55).

**Interfaces:** Produces the reference shell helpers that Task 4 copies into bash verbatim: `lock_acquire`, `lock_release`, `manifest_load`, `manifest_get`, `manifest_set`, `manifest_write`, `precheck`.

- [ ] **Step 1: Run the POSIX tests to see them fail**

Run: `tests/conformance/run.sh -k "posix"`
Expected: new-behaviour cases fail; baseline passes.

- [ ] **Step 2: Options and env**

Add defaults after the existing ones (L33-55):
```sh
ONLY_CHANGED=false
FORCE=false
LOCK_FILE="${GEOIP_LOCK_FILE:-}"
LOCK_TIMEOUT="${GEOIP_LOCK_TIMEOUT:-1800}"
case "${GEOIP_ONLY_CHANGED:-}" in true|1|yes) ONLY_CHANGED=true ;; esac
MAX_RETRIES="${GEOIP_MAX_RETRIES:-3}"
TIMEOUT="${GEOIP_TIMEOUT:-1800}"
LOG_FILE="${GEOIP_LOG_FILE:-}"
```
(replace the existing literal `MAX_RETRIES=3`, `TIMEOUT=1800`, `LOG_FILE=""` assignments with these). Parser cases:
```sh
        --only-changed) ONLY_CHANGED=true; shift ;;
        --force) FORCE=true; shift ;;
        --lock-file) LOCK_FILE="$2"; shift 2 ;;
        --lock-timeout) LOCK_TIMEOUT="$2"; shift 2 ;;
```
`load_config`: accept `only_changed`, `lock_file`, `lock_timeout` with the same "only fill while still at default" rule the function already applies. Add the four options to the usage header and `--help` text.

- [ ] **Step 3: Lock helpers**

```sh
LOCK_DIR_HELD=""

lock_release() {
    if [ -n "$LOCK_DIR_HELD" ]; then
        rm -rf "$LOCK_DIR_HELD"
        LOCK_DIR_HELD=""
    fi
}

lock_acquire() {
    [ -n "$LOCK_FILE" ] || return 0
    waited=0
    if command -v flock >/dev/null 2>&1 && [ -z "${GEOIP_LOCK_FORCE_FALLBACK:-}" ]; then
        exec 9>>"$LOCK_FILE" || { log ERROR "Cannot open lock file $LOCK_FILE"; return 1; }
        until flock -n 9; do
            if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
                log ERROR "Timed out after $LOCK_TIMEOUT s waiting for lock $LOCK_FILE"
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
        done
        printf 'pid=%s host=%s started=%s\n' "$$" "$(uname -n)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_FILE"
        return 0
    fi
    stale="${GEOIP_LOCK_STALE_SECONDS:-$((TIMEOUT + 300))}"
    until mkdir "$LOCK_FILE.d" 2>/dev/null; do
        now=$(date +%s)
        held=$(cat "$LOCK_FILE.d/started" 2>/dev/null || echo "$now")
        if [ $((now - held)) -gt "$stale" ]; then
            rm -rf "$LOCK_FILE.d"
            continue
        fi
        if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
            log ERROR "Timed out after $LOCK_TIMEOUT s waiting for lock $LOCK_FILE"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    date +%s > "$LOCK_FILE.d/started"
    LOCK_DIR_HELD="$LOCK_FILE.d"
    trap 'lock_release' EXIT
    trap 'lock_release; exit 129' HUP
    trap 'lock_release; exit 130' INT
    trap 'lock_release; exit 143' TERM
}
```
If the script already sets `EXIT`/signal traps anywhere, call `lock_release` from those handlers instead of replacing them. Call `lock_acquire || exit 1` in `main` after `create_target_dir` and before the `/auth` call.

- [ ] **Step 4: Manifest and pre-check helpers**

```sh
MANIFEST_ENTRIES=""

manifest_load() {
    MANIFEST_ENTRIES=""
    m="$TARGET_DIR/.geoip-update.json"
    [ -f "$m" ] || return 0
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$n:$line" in
            '1:{'|'2:  "version": 1,'|'3:  "files": {') continue ;;
        esac
        case "$line" in
            '  }'|'}') continue ;;
        esac
        entry=$(printf '%s\n' "$line" | sed -n 's/^    "\([^"]*\)": {"etag": "\([^"]*\)", "last_modified": "\([^"]*\)", "size": \([0-9][0-9]*\)},\{0,1\}$/\1|\2|\3|\4/p')
        if [ -z "$entry" ]; then
            log WARN "Ignoring unreadable manifest $m"
            MANIFEST_ENTRIES=""
            return 0
        fi
        MANIFEST_ENTRIES="${MANIFEST_ENTRIES}${entry}
"
    done < "$m"
    [ "$n" -ge 5 ] || MANIFEST_ENTRIES=""
}

manifest_get() {
    printf '%s' "$MANIFEST_ENTRIES" | grep -F "$1|" | grep "^$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')|" | head -n 1
}

manifest_set() {
    case "$2$3" in *'"'*|*'\'*) return 0 ;; esac
    MANIFEST_ENTRIES=$(printf '%s' "$MANIFEST_ENTRIES" | grep -v "^$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')|")
    MANIFEST_ENTRIES="${MANIFEST_ENTRIES:+$MANIFEST_ENTRIES
}$1|$2|$3|$4
"
}

manifest_write() {
    m="$TARGET_DIR/.geoip-update.json"
    entries=$(printf '%s' "$MANIFEST_ENTRIES" | grep -v '^$' | sort)
    total=$(printf '%s\n' "$entries" | grep -c . || true)
    {
        printf '{\n  "version": 1,\n  "files": {\n'
        i=0
        printf '%s\n' "$entries" | while IFS='|' read -r name etag lm size; do
            [ -n "$name" ] || continue
            i=$((i + 1))
            comma=","
            [ "$i" -lt "$total" ] || comma=""
            printf '    "%s": {"etag": "%s", "last_modified": "%s", "size": %s}%s\n' "$name" "$etag" "$lm" "$size" "$comma"
        done
        printf '  }\n}\n'
    } > "$m.part" && mv "$m.part" "$m"
}

# precheck URL [ETAG] -> sets PC_STATUS, PC_ETAG, PC_LM, PC_TOTAL
precheck() {
    hdr=$(mktemp)
    if [ -n "${2:-}" ]; then
        PC_STATUS=$(curl -sS -o /dev/null -D "$hdr" -r 0-0 -H "If-None-Match: \"$2\"" --max-time 60 -w '%{http_code}' "$1" 2>/dev/null || echo 000)
    else
        PC_STATUS=$(curl -sS -o /dev/null -D "$hdr" -r 0-0 --max-time 60 -w '%{http_code}' "$1" 2>/dev/null || echo 000)
    fi
    PC_ETAG=$(tr -d '\r' < "$hdr" | sed -n 's/^[Ee][Tt][Aa][Gg]: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | tail -n 1)
    PC_LM=$(tr -d '\r' < "$hdr" | sed -n 's/^[Ll][Aa][Ss][Tt]-[Mm][Oo][Dd][Ii][Ff][Ii][Ee][Dd]: *//p' | tail -n 1)
    PC_TOTAL=$(tr -d '\r' < "$hdr" | sed -n 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Rr][Aa][Nn][Gg][Ee]: *bytes [0-9]*-[0-9]*\/\([0-9]*\)$/\1/p' | tail -n 1)
    rm -f "$hdr"
}
```

- [ ] **Step 5: Wire change detection into the per-database flow**

In the function that handles one database (it receives `db_name` and `url`, ~L490), before the existing download:
```sh
    if [ "$ONLY_CHANGED" = true ]; then
        out="$TARGET_DIR/$db_name"
        entry=$(manifest_get "$db_name")
        if [ "$FORCE" = false ] && [ -f "$out" ] && [ -n "$entry" ]; then
            known_etag=$(printf '%s' "$entry" | cut -d'|' -f2)
            known_size=$(printf '%s' "$entry" | cut -d'|' -f4)
            if [ "$(wc -c < "$out" | tr -d ' ')" = "$known_size" ]; then
                precheck "$url" "$known_etag"
                if [ "$PC_STATUS" = 304 ]; then
                    log INFO "Unchanged: $db_name"
                    return 0
                fi
            fi
        fi
        precheck "$url"
        before_etag="$PC_ETAG"; before_lm="$PC_LM"
    fi
```
After the existing successful `mv "$temp_file" "$output_file"` and before `return 0`:
```sh
    if [ "$ONLY_CHANGED" = true ]; then
        precheck "$url" "$before_etag"
        if [ "$PC_STATUS" != 304 ]; then
            log WARN "$db_name changed during download; restarting"
            rm -f "$output_file.part"
            ONLY_CHANGED_RESTARTS=$(( ${ONLY_CHANGED_RESTARTS:-0} + 1 ))
            [ "$ONLY_CHANGED_RESTARTS" -le "$MAX_RETRIES" ] || return 1
            download_database "$db_name" "$url"
            return $?
        fi
        echo "$db_name|$before_etag|$before_lm|$(wc -c < "$output_file" | tr -d ' ')" >> "$TEMP_DIR/manifest.updates"
    fi
```
(Adapt the recursive call to the function's real name and signature. Downloads run as background jobs, so results come back through `$TEMP_DIR/manifest.updates`, not the shell variable.) In the code that runs after all jobs finish (before `rm -rf "$TEMP_DIR"`, L682):
```sh
    if [ "$ONLY_CHANGED" = true ]; then
        if [ -f "$TEMP_DIR/manifest.updates" ]; then
            while IFS='|' read -r n e l s; do manifest_set "$n" "$e" "$l" "$s"; done < "$TEMP_DIR/manifest.updates"
        fi
        manifest_write
    fi
```
Call `manifest_load` once after `lock_acquire` when `ONLY_CHANGED=true`. Ensure the existing code removes a stale `<name>.part` that is not a resumable download of the same object before downloading (test `test_stale_part_file_still_ends_with_a_complete_file`): in `--only-changed` mode delete `<name>.part` before the first attempt; in default mode keep today's behaviour.

- [ ] **Step 6: Version and help**

`VERSION="2.1.0-posix"`. Usage/help lists the four options and the env vars `GEOIP_ONLY_CHANGED`, `GEOIP_LOCK_FILE`, `GEOIP_LOCK_TIMEOUT`, `GEOIP_TIMEOUT`, `GEOIP_MAX_RETRIES`, `GEOIP_LOG_FILE`.

- [ ] **Step 7: Run and commit**

Run: `tests/conformance/run.sh -k "posix"` — expected: all POSIX cases pass, including baseline and the fallback lock case. Then `tests/conformance/run.sh tests/conformance/test_baseline.py` — expected: every client's baseline still passes.
```bash
git add cli/geoip-update-posix.sh
git commit -m "feat(cli-posix): --only-changed, --force and shared-path --lock-file; GEOIP_* env parity"
```

---

### Task 4: bash client (`cli/geoip-update.sh`)

**Files:** Modify `cli/geoip-update.sh` (defaults ~L50-70 incl. `LOCK_FILE=/tmp/geoip-update.lock` L58, parser L137-198, `acquire_lock` L271, `cleanup` trap L309-332, `download_database` ~L480-600, `update_databases` L602-690).

**Interfaces:** Consumes the Task 3 helpers (`lock_acquire`, `lock_release`, `manifest_load`, `manifest_get`, `manifest_set`, `manifest_write`, `precheck`) — copy them verbatim from `cli/geoip-update-posix.sh` (they are POSIX and run unchanged in bash). Rename the existing PID-lock variable so it no longer collides: the old `LOCK_FILE` becomes `PID_LOCK_FILE`; the new user-supplied path is `LOCK_FILE`.

- [ ] **Step 1: Confirm red:** `tests/conformance/run.sh -k "bash"`.
- [ ] **Step 2: Options/env:** add `--only-changed`, `--force`, `--lock-file`, `--lock-timeout` to the parser and help; env defaults exactly as Task 3 Step 2 plus `DATABASES="${GEOIP_DATABASES:-all}"` (keep the existing default when unset), `GEOIP_CONCURRENT` (already read), `GEOIP_LOG_FILE` (already read), `GEOIP_TIMEOUT`, `GEOIP_MAX_RETRIES`. After parsing: if `LOCK_FILE` is set and `USE_LOCK=false` (from `--no-lock`) → `error "--lock-file and --no-lock cannot be combined"` (exit 1).
- [ ] **Step 3: Lock selection:** if `LOCK_FILE` is set, call `lock_acquire || exit 1` instead of `acquire_lock`; otherwise keep `acquire_lock` exactly as today. Make the existing `cleanup` EXIT trap call `lock_release`, and do not let `lock_acquire` replace that trap (drop the `trap` lines from the copied `lock_acquire` and rely on `cleanup`; add `INT`/`TERM`/`HUP` traps that call `cleanup` if none exist).
- [ ] **Step 4: Atomic staging:** change `temp_file="$TEMP_DIR/$db_name"` (L487) to `temp_file="$TARGET_DIR/$db_name.part"`; the final `mv` (L592) stays and is now a same-directory rename. On download failure remove `$temp_file` (as POSIX does). Keep `TEMP_DIR` for its other uses.
- [ ] **Step 5: Change detection:** wire it exactly as Task 3 Step 5 (pre-check before, verify after, `$TEMP_DIR/manifest.updates`, `manifest_write` after all jobs). bash already uses `jq` for the `/auth` map; do not use `jq` for the manifest (same helpers as POSIX keep the format identical).
- [ ] **Step 6: Run and commit:** `tests/conformance/run.sh -k "bash"` all pass; `tests/conformance/run.sh tests/conformance/test_baseline.py` all pass.
```bash
git add cli/geoip-update.sh
git commit -m "feat(cli-bash): --only-changed, --force, shared-path --lock-file, in-directory staging, GEOIP_* env parity"
```

---

### Task 5: Python client (`cli/python/geoip-update.py`) — also covers cron and k8s

**Files:** Modify `cli/python/geoip-update.py` (`Config` L111-125, `LockFile` L128-243, `__init__`/temp dir L294, `authenticate` L316-363, `download_database` L440-540, `update_databases` L550-590, click options L901-917, `main` L925-967). Modify `cli/python-cron/entrypoint.sh` only if the new env vars do not reach the job (verify: supercronic passes the container environment to jobs; if it does, no change).

**Interfaces:** New module-level helpers in the same file:

```python
MANIFEST_NAME = ".geoip-update.json"


def load_manifest(target: Path) -> dict:
    path = target / MANIFEST_NAME
    try:
        files = json.loads(path.read_text())["files"]
        return {n: {"etag": str(e["etag"]), "last_modified": str(e["last_modified"]), "size": int(e["size"])} for n, e in files.items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def _safe(value: str) -> bool:
    return not any(c in value for c in '"\\') and all(ord(c) >= 32 for c in value)


def write_manifest(target: Path, entries: dict) -> None:
    rows = [(n, e) for n, e in sorted(entries.items()) if _safe(n) and _safe(e["etag"]) and _safe(e["last_modified"])]
    lines = ["{", '  "version": 1,', '  "files": {']
    for i, (name, e) in enumerate(rows):
        comma = "," if i < len(rows) - 1 else ""
        lines.append(f'    "{name}": {{"etag": "{e["etag"]}", "last_modified": "{e["last_modified"]}", "size": {e["size"]}}}{comma}')
    lines += ["  }", "}"]
    part = target / (MANIFEST_NAME + ".part")
    part.write_text("\n".join(lines) + "\n")
    os.replace(part, target / MANIFEST_NAME)


class SharedLock:
    def __init__(self, path: Path, timeout: int):
        self.path, self.timeout, self.handle = path, timeout, None

    def __enter__(self):
        self.handle = open(self.path, "a+")
        waited = 0
        while True:
            try:
                if os.name == "nt":
                    import msvcrt
                    self.handle.seek(0)
                    msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if waited >= self.timeout:
                    self.handle.close()
                    raise TimeoutError(f"Timed out after {self.timeout} s waiting for lock {self.path}")
                time.sleep(1)
                waited += 1
        self.handle.seek(0)
        self.handle.truncate()
        self.handle.write(f"pid={os.getpid()} host={socket.gethostname()} started={datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
        self.handle.flush()
        return self

    def __exit__(self, *exc):
        if self.handle:
            self.handle.close()
```

`precheck(session, url, etag=None) -> (status, etag, last_modified, total)`: `GET` with `Range: bytes=0-0` (+ `If-None-Match: "<etag>"`), read headers, strip quotes from `ETag`, parse total from `Content-Range`.

- [ ] **Step 1: Confirm red:** `tests/conformance/run.sh -k "python"`.
- [ ] **Step 2: Options/env:** click options `--only-changed` (flag), `--force` (flag), `--lock-file` (path), `--lock-timeout` (int, default from `GEOIP_LOCK_TIMEOUT` or 1800). `Config` gains `only_changed`, `force`, `lock_file`, `lock_timeout`. In `main`, extend the env layer to read `GEOIP_DATABASES` (comma list), `GEOIP_CONCURRENT`, `GEOIP_LOG_FILE`, `GEOIP_TIMEOUT`, `GEOIP_MAX_RETRIES`, `GEOIP_ONLY_CHANGED` (`true`/`1`/`yes`), `GEOIP_LOCK_FILE`, `GEOIP_LOCK_TIMEOUT`, keeping the existing precedence (defaults < YAML < env < flags). YAML keys `only_changed`, `lock_file`, `lock_timeout`. `--lock-file` with `--no-lock` → print `--lock-file and --no-lock cannot be combined` and `sys.exit(1)`. Version `1.2.0`.
- [ ] **Step 3: Lock selection:** with `lock_file`, wrap the run in `SharedLock` (on `TimeoutError` log its message and `sys.exit(1)`) instead of `LockFile`; without it, today's `LockFile` path unchanged.
- [ ] **Step 4: Atomic staging:** stage at `target_dir / f"{name}.part"` (replace `temp_dir / name`, L459) and `os.replace` into place (replace `shutil.move`, L534). Remove the `.part` on failure. In `--only-changed` mode delete any existing `.part` before the first attempt.
- [ ] **Step 5: Change detection:** in `update_databases`, load the manifest when `only_changed`; per database apply the spec flow (size check → `precheck(url, etag)` → `304` logs `Unchanged: <name>` and counts as success; otherwise `precheck(url)` to capture ETag/Last-Modified, download, `precheck(url, before_etag)` after; non-`304` → delete `.part`, restart, counted against `max_retries`). Collect updates; call `write_manifest` once after all downloads, merging with entries for unrequested files.
- [ ] **Step 6: Cron/k8s check:** `docker build -f cli/python-cron/Dockerfile cli` and `docker run --rm -e GEOIP_API_KEY=x <image> sh -c 'python /app/geoip-update.py --help'` prints the new options. If supercronic does not pass env to the job (check `docs` of the pinned supercronic version or run a job printing `env`), pass them through in `entrypoint.sh`.
- [ ] **Step 7: Run and commit:** `tests/conformance/run.sh -k "python"` all pass; baseline for all clients passes.
```bash
git add cli/python cli/python-cron cli/python-k8s
git commit -m "feat(cli-python): --only-changed, --force, shared-path --lock-file, in-directory staging, GEOIP_* env parity"
```

---

### Task 6: Go client (`cli/go/`)

**Files:** Modify `cli/go/main.go` (`version` L28, `LockFile` L154-204, `newGeoIPUpdater`/temp dir L341, `downloadDatabase` L399-520, update loop L600-640, `parseFlags` L692-815, `main` L1260-1300). Create `cli/go/lock_unix.go` (`//go:build !windows`), `cli/go/lock_windows.go` (`//go:build windows`), `cli/go/manifest.go`, `cli/go/manifest_test.go`. Modify `cli/go/Makefile` (VERSION 1.2.0).

**Interfaces:**

`cli/go/lock_unix.go`:
```go
//go:build !windows

package main

import (
	"os"
	"syscall"
)

func tryLock(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
}
```

`cli/go/lock_windows.go`:
```go
//go:build windows

package main

import (
	"os"
	"syscall"
)

func openLockFile(path string) (*os.File, error) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

func tryLock(f *os.File) error { return nil }
```
On Unix add `func openLockFile(path string) (*os.File, error) { return os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644) }` in `lock_unix.go`. On Windows an open with share mode 0 *is* the lock: a second `openLockFile` fails until the holder exits.

Shared acquire (in `main.go` or `lock.go`, build-tag free):
```go
func acquireSharedLock(path string, timeout int) (*os.File, error) {
	for waited := 0; ; waited++ {
		f, err := openLockFile(path)
		if err == nil {
			if err = tryLock(f); err == nil {
				f.Truncate(0)
				host, _ := os.Hostname()
				fmt.Fprintf(f, "pid=%d host=%s started=%s\n", os.Getpid(), host, time.Now().UTC().Format("2006-01-02T15:04:05Z"))
				return f, nil
			}
			f.Close()
		}
		if waited >= timeout {
			return nil, fmt.Errorf("Timed out after %d s waiting for lock %s", timeout, path)
		}
		time.Sleep(time.Second)
	}
}
```

`cli/go/manifest.go`:
```go
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const manifestName = ".geoip-update.json"

type manifestEntry struct {
	ETag         string `json:"etag"`
	LastModified string `json:"last_modified"`
	Size         int64  `json:"size"`
}

func loadManifest(dir string) map[string]manifestEntry {
	data, err := os.ReadFile(filepath.Join(dir, manifestName))
	if err != nil {
		return map[string]manifestEntry{}
	}
	var doc struct {
		Files map[string]manifestEntry `json:"files"`
	}
	if json.Unmarshal(data, &doc) != nil || doc.Files == nil {
		return map[string]manifestEntry{}
	}
	return doc.Files
}

func safeValue(s string) bool {
	return !strings.ContainsAny(s, "\"\\") && !strings.ContainsFunc(s, func(r rune) bool { return r < 32 })
}

func writeManifest(dir string, entries map[string]manifestEntry) error {
	names := make([]string, 0, len(entries))
	for n, e := range entries {
		if safeValue(n) && safeValue(e.ETag) && safeValue(e.LastModified) {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString("{\n  \"version\": 1,\n  \"files\": {\n")
	for i, n := range names {
		e := entries[n]
		comma := ","
		if i == len(names)-1 {
			comma = ""
		}
		fmt.Fprintf(&b, "    \"%s\": {\"etag\": \"%s\", \"last_modified\": \"%s\", \"size\": %d}%s\n", n, e.ETag, e.LastModified, e.Size, comma)
	}
	b.WriteString("  }\n}\n")
	part := filepath.Join(dir, manifestName+".part")
	if err := os.WriteFile(part, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(part, filepath.Join(dir, manifestName))
}
```
(`strings.ContainsFunc` needs Go ≥ 1.21, which `go.mod` declares.)

`precheck(url, etag string) (status int, etag string, lastModified string, total int64, err error)` in `main.go`: `GET` with `Range: bytes=0-0` (+ `If-None-Match`), using the existing HTTP client.

- [ ] **Step 1: `cli/go/manifest_test.go`** (write first, run `go test ./...` in the image → fail):
```go
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestManifestRoundTripIsCanonical(t *testing.T) {
	dir := t.TempDir()
	in := map[string]manifestEntry{
		"b.BIN":  {ETag: "e2-46", LastModified: "Mon, 23 Mar 2026 00:34:53 GMT", Size: 2},
		"a.mmdb": {ETag: "e1-16", LastModified: "Mon, 05 Oct 2026 00:38:39 GMT", Size: 1},
		"bad":    {ETag: "has\"quote", LastModified: "x", Size: 3},
	}
	if err := writeManifest(dir, in); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, manifestName))
	want := "{\n  \"version\": 1,\n  \"files\": {\n" +
		"    \"a.mmdb\": {\"etag\": \"e1-16\", \"last_modified\": \"Mon, 05 Oct 2026 00:38:39 GMT\", \"size\": 1},\n" +
		"    \"b.BIN\": {\"etag\": \"e2-46\", \"last_modified\": \"Mon, 23 Mar 2026 00:34:53 GMT\", \"size\": 2}\n" +
		"  }\n}\n"
	if string(got) != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	if back := loadManifest(dir); len(back) != 2 || back["a.mmdb"].Size != 1 {
		t.Fatalf("round trip: %+v", back)
	}
}

func TestCorruptManifestIsEmpty(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, manifestName), []byte("{ not json"), 0o644)
	if len(loadManifest(dir)) != 0 {
		t.Fatal("corrupt manifest should be empty")
	}
}
```
- [ ] **Step 2: Flags/env:** `--only-changed`, `--force`, `--lock-file`, `--lock-timeout` (int seconds). Env defaults for `GEOIP_DATABASES`, `GEOIP_CONCURRENT`, `GEOIP_TIMEOUT` (parsed by the existing `timeoutValue`, seconds or duration), `GEOIP_MAX_RETRIES`, `GEOIP_ONLY_CHANGED`, `GEOIP_LOCK_FILE`, `GEOIP_LOCK_TIMEOUT` alongside the existing ones. `--lock-file` with `--no-lock` → stderr `--lock-file and --no-lock cannot be combined`, exit 1. `version = "1.2.0"`.
- [ ] **Step 3: Lock selection:** with `--lock-file` call `acquireSharedLock` (on error print it, exit 1) instead of the PID `LockFile`; keep the file open until exit.
- [ ] **Step 4: Atomic staging:** stage at `filepath.Join(targetDir, name+".part")` (replace the `tempDir` join in `downloadDatabase`), `os.Rename` into place (the cross-device copy fallback becomes unnecessary; keep it harmless). Remove `.part` on failure; in `--only-changed` mode remove a pre-existing `.part` before the first attempt.
- [ ] **Step 5: Change detection** per the spec flow (same as Task 5 Step 5), manifest written once after the goroutines finish, merged with unrequested entries; `Unchanged: <name>` through the existing logger at info level.
- [ ] **Step 6: Run and commit:** `tests/conformance/run.sh -k "go"` all pass (includes `go test ./...`); baseline passes for all clients.
```bash
git add cli/go
git commit -m "feat(cli-go): --only-changed, --force, shared-path --lock-file, in-directory staging, GEOIP_* env parity"
```

---

### Task 7: PowerShell client (`cli/geoip-update.ps1`)

**Files:** Modify `cli/geoip-update.ps1` (header version L69, `param` L73-108, `New-LockFile` L360, temp dir L131, `Invoke-ResumableDownload` L509, move L682/L734, parallel L719-836, finally L1239-1246).

**Interfaces:**
```powershell
function Read-Manifest([string]$Dir) {
    $path = Join-Path $Dir '.geoip-update.json'
    if (-not (Test-Path $path)) { return @{} }
    try {
        $doc = Get-Content -Raw $path | ConvertFrom-Json
        $result = @{}
        foreach ($p in $doc.files.PSObject.Properties) {
            $result[$p.Name] = @{ etag = [string]$p.Value.etag; last_modified = [string]$p.Value.last_modified; size = [long]$p.Value.size }
        }
        return $result
    } catch { return @{} }
}

function Test-SafeValue([string]$Value) { return -not ($Value -match '["\\\x00-\x1f]') }

function Write-Manifest([string]$Dir, [hashtable]$Entries) {
    $names = @($Entries.Keys | Where-Object { (Test-SafeValue $_) -and (Test-SafeValue $Entries[$_].etag) -and (Test-SafeValue $Entries[$_].last_modified) } | Sort-Object { $_ } -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{'); $lines.Add('  "version": 1,'); $lines.Add('  "files": {')
    for ($i = 0; $i -lt $names.Count; $i++) {
        $e = $Entries[$names[$i]]
        $comma = if ($i -lt $names.Count - 1) { ',' } else { '' }
        $lines.Add(('    "{0}": {{"etag": "{1}", "last_modified": "{2}", "size": {3}}}{4}' -f $names[$i], $e.etag, $e.last_modified, $e.size, $comma))
    }
    $lines.Add('  }'); $lines.Add('}')
    $part = Join-Path $Dir '.geoip-update.json.part'
    [System.IO.File]::WriteAllText($part, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    Move-Item -Force $part (Join-Path $Dir '.geoip-update.json')
}

function Enter-SharedLock([string]$Path, [int]$Timeout) {
    for ($waited = 0; ; $waited++) {
        try {
            $stream = [System.IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None')
            $stream.SetLength(0)
            $info = [System.Text.Encoding]::UTF8.GetBytes(("pid={0} host={1} started={2}`n" -f $PID, [System.Net.Dns]::GetHostName(), [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')))
            $stream.Write($info, 0, $info.Length); $stream.Flush()
            return $stream
        } catch [System.IO.IOException] {
            if ($waited -ge $Timeout) { throw "Timed out after $Timeout s waiting for lock $Path" }
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-Precheck([string]$Url, [string]$ETag) {
    $headers = @{ Range = 'bytes=0-0' }
    if ($ETag) { $headers['If-None-Match'] = '"' + $ETag + '"' }
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -UseBasicParsing -MaximumRedirection 5
        $status = [int]$r.StatusCode; $h = $r.Headers
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $status = [int]$resp.StatusCode; $h = $resp.Headers
    }
    $etagValue = ([string]($h['ETag'] | Select-Object -First 1)).Trim('"')
    $lm = [string]($h['Last-Modified'] | Select-Object -First 1)
    return @{ Status = $status; ETag = $etagValue; LastModified = $lm }
}
```
On pwsh 7, `HttpResponseMessage.Headers` differ from PS 5.1 `WebResponse.Headers` (and `ETag`/`Last-Modified` may sit under `Content.Headers`); handle both shapes and verify `304` and `206` paths in the image (pwsh 7) — PS 5.1 is untestable in CI, so keep the 5.1 branch to `WebResponse.Headers['ETag']` and note it in the report.

- [ ] **Step 1: Confirm red:** `tests/conformance/run.sh -k "powershell"`.
- [ ] **Step 2: Parameters/env:** `[switch]$OnlyChanged`, `[switch]$Force`, `[string]$LockFile = $env:GEOIP_LOCK_FILE`, `[int]$LockTimeout = ($env:GEOIP_LOCK_TIMEOUT ?? 1800)` written in PS 5.1-compatible syntax (no `??`): `[int]$LockTimeout = $(if ($env:GEOIP_LOCK_TIMEOUT) { [int]$env:GEOIP_LOCK_TIMEOUT } else { 1800 })`. Same pattern for `GEOIP_DATABASES` (split on `,`), `GEOIP_TIMEOUT`, `GEOIP_MAX_RETRIES`, `GEOIP_CONCURRENT` (replaces the hardcoded `$maxParallel = 2` default), `GEOIP_ONLY_CHANGED` (`true`/`1`/`yes` sets `$OnlyChanged`). `-LockFile` with `-NoLock` → `Exit-WithError -Message '--lock-file and --no-lock cannot be combined' -ExitCode 1`. Header version `1.2.0`. Update the comment-based help.
- [ ] **Step 3: Lock selection:** with `-LockFile` use `Enter-SharedLock` (catch the throw → log it, exit 1), dispose the stream in the existing `finally`; otherwise `New-LockFile` as today.
- [ ] **Step 4: Atomic staging:** download to `Join-Path $TargetDirectory "$name.part"`, `Move-Item -Force` into place (same directory). Remove `.part` on failure; in `-OnlyChanged` mode remove a pre-existing `.part` first. The `Start-Job` parallel path must receive the new staging path.
- [ ] **Step 5: Change detection** per the spec flow, manifest written once at the end (merged), `Unchanged: <name>` through the script's logger.
- [ ] **Step 6: Run and commit:** `tests/conformance/run.sh -k "powershell"` all pass; baseline passes for all clients.
```bash
git add cli/geoip-update.ps1
git commit -m "feat(cli-ps1): -OnlyChanged, -Force, shared-path -LockFile, in-directory staging, GEOIP_* env parity"
```

---

### Task 8: Cross-client manifest compatibility, docs, version bump

**Files:**
- Create: `tests/conformance/test_manifest_compat.py`
- Modify docs: `README.md`, `cli/README.md`, `cli/python/README.md`, `cli/go/README.md`, `cli/python-cron/README.md` (remove `GEOIP_LOG_LEVEL`), `cli/python-k8s/README.md`, `cli/systemd/README.md`, `docker-scripts/README.md`, `docs/LARAVEL_INTEGRATION.md`, `docs/TROUBLESHOOTING.md`, `USAGE_EXAMPLES.md`, `cli/config.example.yaml`, `CHANGELOG.md`
- Modify versions: `cli/setup.py:13`, `docker-scripts/Dockerfile:17,24`, `api-server/app.py:335,829,1538`, `k8s/base/cronjob.yaml:9`, `k8s/base/cronjob-secure.yaml:9,26`, `k8s/overlays/prod/kustomization.yaml:74`

- [ ] **Step 1: Compatibility test**

```python
import itertools

import pytest

from clients import CLIENTS, run
from conftest import DBS


@pytest.mark.parametrize("writer,reader", [p for p in itertools.permutations(CLIENTS, 2)])
def test_manifest_written_by_one_client_is_read_by_another(writer, reader, server, target):
    assert run(writer, server, target, extra=["only_changed"]).returncode == 0
    server.reset_stats()
    result = run(reader, server, target, extra=["only_changed"])
    assert result.returncode == 0, result.stdout + result.stderr
    for n in DBS:
        assert server.stats(n)["full"] == 0
        assert f"Unchanged: {n}" in result.stdout + result.stderr
```
Run: `tests/conformance/run.sh tests/conformance/test_manifest_compat.py` → all 30 pairs pass.

- [ ] **Step 2: Docs.** Every listed document describes `--only-changed`/`--force`/`--lock-file`/`--lock-timeout` (PowerShell names where relevant), the manifest file, the lock semantics (waits, kernel-released, timeout, `--no-lock` conflict), atomic `.part` staging, and the full unified env list. Recommended shared-volume/daily setup: `--only-changed --lock-file <target>/.geoip-update.lock`. Do not mention `GEOIP_LOCK_FORCE_FALLBACK` or `GEOIP_LOCK_STALE_SECONDS`. `cli/config.example.yaml`: add `only_changed`, `lock_file`, `lock_timeout`, and fix its `timeout`/`max_concurrent` examples to the real defaults (1800, 2).
- [ ] **Step 3: Versions.** `1.1.3` → `1.2.0` in the listed files (`v1.1.3-prod` → `v1.2.0-prod`). `CHANGELOG.md`: a `1.2.0` entry (Added: the four options, manifest, env parity; Changed: in-directory `.part` staging in bash/Python/Go/PowerShell; Fixed: cron/k8s symlinks; Tests: conformance suite + CI). `grep -rn "1\.1\.3" --exclude-dir=.git .` returns only historical CHANGELOG lines.
- [ ] **Step 4: Full run and commit**

Run: `tests/conformance/run.sh` → every test passes; `go test` passes.
```bash
git add tests/conformance/test_manifest_compat.py README.md USAGE_EXAMPLES.md CHANGELOG.md cli docker-scripts docs api-server/app.py k8s
git commit -m "docs: v1.2.0 options, manifest and locking; cross-client manifest test; bump to 1.2.0"
```
(Only stage the listed files; never `.serena/project.yml`.)

---

### Task 9: Release readiness (controller, not a subagent)

- [ ] `tests/conformance/run.sh` once more from a clean `docker build --no-cache`; report the literal summary line.
- [ ] `docker build -f docker-scripts/Dockerfile .` succeeds and `docker run --rm --entrypoint "" <tmp image built FROM alpine with COPY --from=<scripts image> /opt/geoip /opt/geoip> sh /opt/geoip/geoip-update-posix.sh --version` prints `2.1.0-posix`.
- [ ] `git status --short` shows only `.serena/project.yml` modified; `git log --oneline main..HEAD` lists the commits.
- [ ] Report to Nuno: the branch, commits, test summary, and the release steps (push branch, PR, merge, `chore(release): v1.2.0`, tag `v1.2.0` per `docs/RELEASE_PROCESS.md`). Nothing is pushed.
