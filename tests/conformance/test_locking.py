import os
import signal
import time

import pytest

from clients import run, start
from conftest import wait_for_bytes


def _lock(target):
    return str(target / ".geoip-update.lock")


def test_second_run_waits_then_finds_everything_unchanged(client, server, target):
    server.slow("GeoIP2-City.mmdb", 6)
    extra = ["only_changed", ("lock_file", _lock(target))]
    first = start(client, server, target, extra=extra)
    wait_for_bytes(server, "GeoIP2-City.mmdb")
    server_full_before = server.stats("GeoIP2-City.mmdb")["full"]
    second = run(client, server, target, extra=extra)
    first_output, _ = first.communicate(timeout=120)
    assert first.returncode == 0, first_output
    assert second.returncode == 0, second.stdout + second.stderr
    assert server.stats("GeoIP2-City.mmdb")["full"] == server_full_before
    assert "Unchanged: GeoIP2-City.mmdb" in second.stdout + second.stderr


def test_lock_timeout_exits_1_with_message(client, server, target):
    server.slow("GeoIP2-City.mmdb", 8)
    first = start(client, server, target, extra=[("lock_file", _lock(target))])
    wait_for_bytes(server, "GeoIP2-City.mmdb")
    second = run(client, server, target, extra=[("lock_file", _lock(target)), ("lock_timeout", 1)])
    first.communicate(timeout=120)
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
    wait_for_bytes(server, "GeoIP2-City.mmdb")
    first.send_signal(signal.SIGKILL)
    first.wait(timeout=30)
    first.stdout.close()
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
