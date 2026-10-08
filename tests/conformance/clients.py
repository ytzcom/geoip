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
    "powershell": ["pwsh", "-NoProfile", "-NonInteractive", "-Command"],
}
_PS_SCRIPT = REPO / "cli/geoip-update.ps1"

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
        if client == "powershell":
            return [name, ",".join(_ps_quote(db) for db in value)]
        return [name, ",".join(value)]
    if client == "powershell":
        return [name, _ps_quote(value)]
    return [name, str(value)]


def _ps_quote(value) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _ps_command(args) -> list[str]:
    return _BASE["powershell"] + [" ".join(["&", _ps_quote(_PS_SCRIPT), *args]) + "; exit $LASTEXITCODE"]


def command(client, server, target, databases, extra=()) -> list[str]:
    cmd = [] if client == "powershell" else list(_BASE[client])
    cmd += flag(client, "api_key", server.api_key)
    cmd += flag(client, "endpoint", server.endpoint)
    cmd += flag(client, "directory", target)
    if databases is not None:
        cmd += flag(client, "databases", databases)
    for item in extra:
        cmd += flag(client, *item) if isinstance(item, tuple) else flag(client, item)
    return _ps_command(cmd) if client == "powershell" else cmd


def _env(env):
    base = {k: v for k, v in os.environ.items() if not k.startswith("GEOIP_")}
    base.update(env or {})
    return base


def run(client, server, target, *, databases=("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"), extra=(), env=None, timeout=120, bare=False):
    if bare:
        cmd = _ps_command([]) if client == "powershell" else list(_BASE[client])
    else:
        cmd = command(client, server, target, databases, extra)
    return subprocess.run(cmd, capture_output=True, text=True, env=_env(env), timeout=timeout)


def start(client, server, target, *, databases=("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"), extra=(), env=None):
    return subprocess.Popen(command(client, server, target, databases, extra), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=_env(env))


def available(client: str) -> bool:
    exe = {"posix-dash": "dash", "posix-busybox": "busybox", "bash": "bash", "python": "python3", "go": str(GO_BINARY), "powershell": "pwsh"}[client]
    return shutil.which(exe) is not None or Path(exe).exists()
