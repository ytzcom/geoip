import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests/conformance"))

from fake_server import FakeServer, fixture_bytes

CITY, PROXY = "GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"
DBS = (CITY, PROXY)
WINDOWS = os.name == "nt"
PS_SCRIPT = REPO / "cli/geoip-update.ps1"
WORK = Path(tempfile.mkdtemp(prefix="geoip-smoke-"))
GO_BINARY = WORK / ("geoip-update.exe" if WINDOWS else "geoip-update")

failures = []


class Server(FakeServer):
    def __init__(self):
        super().__init__()
        for name in DBS:
            self.put(name, fixture_bytes(name))


def command(client, server, target, options):
    if client in ("powershell", "pwsh"):
        names = {"only_changed": "-OnlyChanged", "quiet": "-Quiet", "lock_file": "-LockFile", "lock_timeout": "-LockTimeout", "max_retries": "-MaxRetries"}
        exe = "powershell.exe" if client == "powershell" else "pwsh"
        cmd = [exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(PS_SCRIPT),
               "-ApiKey", server.api_key, "-ApiEndpoint", server.endpoint, "-TargetDirectory", str(target), "-Databases", ",".join(DBS)]
    else:
        names = {"only_changed": "--only-changed", "lock_file": "--lock-file", "lock_timeout": "--lock-timeout", "max_retries": "--retries"}
        cmd = [str(GO_BINARY)] if client == "go" else [sys.executable, str(REPO / "cli/python/geoip-update.py")]
        cmd += ["--api-key", server.api_key, "--endpoint", server.endpoint, "--directory", str(target)]
        cmd += ["--databases", ",".join(DBS)] if client == "go" else [x for db in DBS for x in ("--databases", db)]
    for option in options:
        if isinstance(option, tuple):
            cmd += [names[option[0]], str(option[1])]
        else:
            cmd.append(names[option])
    return cmd


def _env():
    return {k: v for k, v in os.environ.items() if not k.startswith("GEOIP_")}


def run(client, server, target, options=()):
    result = subprocess.run(command(client, server, target, options), capture_output=True, text=True, encoding="utf-8", errors="replace", env=_env(), timeout=300)
    return result.returncode, result.stdout + result.stderr


def start(client, server, target, options=()):
    return subprocess.Popen(command(client, server, target, options), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", env=_env())


def wait_for_bytes(server, proc, deadline=30):
    end = time.monotonic() + deadline
    while server.stats(CITY)["bytes"] == 0:
        if proc.poll() is not None:
            raise AssertionError(f"first run exited {proc.returncode} before downloading {CITY}:\n{proc.communicate()[0]}")
        if time.monotonic() >= end:
            raise AssertionError(f"no bytes of {CITY} served within {deadline} s")
        time.sleep(0.05)


def target_dir(label):
    return Path(tempfile.mkdtemp(prefix=label + "-", dir=WORK))


def expect(condition, message):
    if not condition:
        raise AssertionError(message)


def default_run(client):
    server, target = Server(), target_dir(client)
    try:
        rc, out = run(client, server, target)
        expect(rc == 0, f"exit {rc}\n{out}")
        for name in DBS:
            expect((target / name).read_bytes() == fixture_bytes(name), f"{name} differs from the served bytes\n{out}")
    finally:
        server.close()


def only_changed_twice(client):
    server, target = Server(), target_dir(client)
    try:
        rc, out = run(client, server, target, ["only_changed"])
        expect(rc == 0, f"first run exit {rc}\n{out}")
        rc, out = run(client, server, target, ["only_changed"])
        expect(rc == 0, f"second run exit {rc}\n{out}")
        for name in DBS:
            expect(f"Unchanged: {name}" in out, f"no 'Unchanged: {name}' in the second run\n{out}")
    finally:
        server.close()


def lock_contention(holder, waiter):
    server, target = Server(), target_dir(f"{holder}-{waiter}")
    lock = target / ".geoip-update.lock"
    try:
        server.slow(CITY, 6)
        options = ["only_changed", ("lock_file", lock)]
        first = start(holder, server, target, options)
        wait_for_bytes(server, first)
        full_before = server.stats(CITY)["full"]
        rc, out = run(waiter, server, target, options + [("lock_timeout", 120)])
        first_output, _ = first.communicate(timeout=300)
        expect(first.returncode == 0, f"{holder} (holder) exit {first.returncode}\n{first_output}")
        expect(rc == 0, f"{waiter} (waiter) exit {rc}\n{out}")
        expect(server.stats(CITY)["full"] == full_before, f"{waiter} downloaded {CITY} again instead of waiting\n{out}")
        for name in DBS:
            expect(f"Unchanged: {name}" in out, f"no 'Unchanged: {name}' from {waiter}\n{out}")
    finally:
        server.close()


def quiet_partial_failure(client):
    server, target = Server(), target_dir(client)
    try:
        server.fail(PROXY, 500)
        rc, out = run(client, server, target, ["quiet", ("max_retries", 1)])
        expect(rc == 2, f"exit {rc}, expected 2\n{out}")
    finally:
        server.close()


def go_test():
    result = subprocess.run(["go", "test", "./..."], cwd=REPO / "cli/go", capture_output=True, text=True)
    expect(result.returncode == 0, result.stdout + result.stderr)


def check(label, func, *args):
    began = time.monotonic()
    try:
        func(*args)
    except Exception as e:
        failures.append(label)
        print(f"FAIL {label}: {e}", flush=True)
    else:
        print(f"ok   {label} ({time.monotonic() - began:.1f} s)", flush=True)


def available(client):
    return {"go": True, "python": True, "pwsh": shutil.which("pwsh"), "powershell": shutil.which("powershell.exe")}[client]


def main():
    subprocess.run(["go", "build", "-o", str(GO_BINARY), "."], cwd=REPO / "cli/go", check=True)
    check("go: go test ./...", go_test)
    for client in ("go", "python", "pwsh", "powershell"):
        if not available(client):
            if WINDOWS:
                failures.append(f"{client}: not installed")
                print(f"FAIL {client}: not installed", flush=True)
            else:
                print(f"skip {client}: not installed", flush=True)
            continue
        check(f"{client}: default run", default_run, client)
        check(f"{client}: --only-changed twice", only_changed_twice, client)
        check(f"{client}: --lock-file contention", lock_contention, client, client)
        if client in ("pwsh", "powershell"):
            check(f"{client}: -Quiet partial failure exits 2", quiet_partial_failure, client)
    check("go holds --lock-file, python waits", lock_contention, "go", "python")
    check("python holds --lock-file, go waits", lock_contention, "python", "go")
    shutil.rmtree(WORK, ignore_errors=True)
    if failures:
        print(f"{len(failures)} check(s) failed: " + "; ".join(failures))
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
