import os
import signal
import time
from pathlib import Path

import pytest

from clients import run, start
from conftest import wait_for_bytes


def _lock(target):
    return str(target / ".geoip-update.lock")


def _fallback_env(client, fallback, **extra):
    if fallback and not (client.startswith("posix") or client == "bash"):
        pytest.skip("the mkdir fallback exists only in the shell clients")
    return {"GEOIP_LOCK_FORCE_FALLBACK": "1", **extra} if fallback else None


@pytest.mark.parametrize("fallback", [False, True])
def test_second_run_waits_then_finds_everything_unchanged(client, server, target, fallback):
    env = _fallback_env(client, fallback)
    server.slow("GeoIP2-City.mmdb", 6)
    extra = ["only_changed", ("lock_file", _lock(target))]
    first = start(client, server, target, extra=extra, env=env)
    wait_for_bytes(server, "GeoIP2-City.mmdb", first)
    if fallback:
        assert Path(_lock(target) + ".d").is_dir()
    server_full_before = server.stats("GeoIP2-City.mmdb")["full"]
    second = run(client, server, target, extra=extra, env=env)
    first_output, _ = first.communicate(timeout=120)
    assert first.returncode == 0, first_output
    if not fallback:
        diagnostics = Path(_lock(target)).read_text()
        for key in ("pid=", "host=", "started="):
            assert key in diagnostics, diagnostics
    assert second.returncode == 0, second.stdout + second.stderr
    assert server.stats("GeoIP2-City.mmdb")["full"] == server_full_before
    assert "Unchanged: GeoIP2-City.mmdb" in second.stdout + second.stderr


def test_fallback_lock_of_a_live_run_is_not_stolen(client, server, target):
    env = _fallback_env(client, True, GEOIP_LOCK_STALE_SECONDS="5")
    server.slow("GeoIP2-City.mmdb", 20)
    extra = ["only_changed", ("lock_file", _lock(target))]
    first = start(client, server, target, extra=extra, env=env)
    wait_for_bytes(server, "GeoIP2-City.mmdb", first)
    server_full_before = server.stats("GeoIP2-City.mmdb")["full"]
    second = run(client, server, target, extra=extra + [("lock_timeout", 30)], env=env)
    first_output, _ = first.communicate(timeout=120)
    assert first.returncode == 0, first_output
    assert second.returncode == 0, second.stdout + second.stderr
    assert server.stats("GeoIP2-City.mmdb")["full"] == server_full_before
    for name in ("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"):
        assert f"Unchanged: {name}" in second.stdout + second.stderr
    assert not Path(_lock(target) + ".d").exists()


def test_lock_timeout_exits_1_with_message(client, server, target):
    server.slow("GeoIP2-City.mmdb", 8)
    first = start(client, server, target, extra=[("lock_file", _lock(target))])
    wait_for_bytes(server, "GeoIP2-City.mmdb", first)
    began = time.monotonic()
    second = run(client, server, target, extra=[("lock_file", _lock(target)), ("lock_timeout", 1)])
    waited = time.monotonic() - began
    first_output, _ = first.communicate(timeout=120)
    assert first.returncode == 0, first_output
    assert second.returncode == 1
    assert f"Timed out after 1 s waiting for lock {_lock(target)}" in second.stdout + second.stderr
    assert waited >= 1


@pytest.mark.parametrize("fallback", [False, True])
def test_killed_holder_never_blocks_the_next_run(client, server, target, fallback):
    env = _fallback_env(client, fallback, GEOIP_LOCK_STALE_SECONDS="5")
    server.slow("GeoIP2-City.mmdb", 120)
    extra = [("lock_file", _lock(target))]
    first = start(client, server, target, extra=extra, env=env, new_session=True)
    wait_for_bytes(server, "GeoIP2-City.mmdb", first)
    os.killpg(os.getpgid(first.pid), signal.SIGKILL)
    first.communicate(timeout=30)
    server.slow("GeoIP2-City.mmdb", 0)
    began = time.monotonic()
    second = run(client, server, target, extra=extra + [("lock_timeout", 60)], env=env)
    assert second.returncode == 0, second.stdout + second.stderr
    assert time.monotonic() - began < (30 if fallback else 15)


def test_lock_file_with_no_lock_is_rejected(client, server, target):
    if client.startswith("posix"):
        pytest.skip("the POSIX client has no --no-lock")
    result = run(client, server, target, extra=[("lock_file", _lock(target)), "no_lock"])
    assert result.returncode == 1
    assert "--lock-file and --no-lock cannot be combined" in result.stdout + result.stderr
