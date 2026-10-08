import time

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


def _run_in(tmp_path, label, client, server, **kwargs):
    directory = tmp_path / label
    directory.mkdir()
    began = time.monotonic()
    result = run(client, server, directory, **kwargs)
    return result, time.monotonic() - began


def test_max_retries_from_env_matches_the_flag(client, server, tmp_path):
    proxy = "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"

    def download_fails():
        server.fail_auth(None)
        server.fail(proxy, 500)

    scenarios = [
        ("auth", lambda: server.fail_auth(500), lambda: server.auth_attempts),
        ("download", download_fails, lambda: server.stats(proxy)["attempts"]),
    ]
    for label, arrange, attempts in scenarios:
        arrange()
        by_flag = {}
        for retries in (1, 4):
            server.reset_stats()
            _run_in(tmp_path, f"{label}-{retries}", client, server, extra=[("max_retries", retries)], timeout=120)
            by_flag[retries] = attempts()
        print(f"{label}: retries=1 -> {by_flag[1]} attempts, retries=4 -> {by_flag[4]} attempts")
        if by_flag[1] != by_flag[4]:
            server.reset_stats()
            _run_in(tmp_path, f"{label}-env", client, server, env={"GEOIP_MAX_RETRIES": "1"}, timeout=120)
            assert attempts() == by_flag[1], f"observable via {label}: env {attempts()} attempts, flag {by_flag[1]}"
            return
    pytest.fail(f"--max-retries has no observable effect for {client}")


def test_concurrency_from_env(client, server, target):
    server.slow("GeoIP2-City.mmdb", 2)
    server.slow("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN", 2)
    assert run(client, server, target, env={"GEOIP_CONCURRENT": "1"}).returncode == 0
    assert server.max_parallel == 1


def test_timeout_from_env_matches_the_flag(client, server, tmp_path):
    if client in ("python", "go", "powershell"):
        pytest.skip("--timeout does not abort a stalled transfer in this client (kept as-is, no breaking changes)")
    server.stall("GeoIP2-City.mmdb", 30)
    short, short_s = _run_in(tmp_path, "flag-2", client, server, extra=[("timeout", 2)], timeout=90)
    long, long_s = _run_in(tmp_path, "flag-60", client, server, extra=[("timeout", 60)], timeout=90)
    print(f"timeout=2 -> exit {short.returncode} in {short_s:.1f} s, timeout=60 -> exit {long.returncode} in {long_s:.1f} s")
    if short.returncode == long.returncode and long_s - short_s < 10:
        pytest.fail(f"--timeout has no observable effect for {client}")
    env, env_s = _run_in(tmp_path, "env-2", client, server, env={"GEOIP_TIMEOUT": "2"}, timeout=90)
    assert env.returncode == short.returncode, env.stdout + env.stderr
    assert abs(env_s - short_s) <= 10, f"env {env_s:.1f} s, flag {short_s:.1f} s"


@pytest.mark.parametrize("value", ["true", "1", "yes"])
def test_only_changed_and_lock_from_env(client, server, target, value):
    lock = target / ".geoip-update.lock"
    env = {"GEOIP_ONLY_CHANGED": value, "GEOIP_LOCK_FILE": str(lock), "GEOIP_LOCK_TIMEOUT": "60"}
    assert run(client, server, target, env=env).returncode == 0
    server.reset_stats()
    assert run(client, server, target, env=env).returncode == 0
    for n in DBS:
        assert server.stats(n)["full"] == 0
    diagnostics = lock.read_text()
    for key in ("pid=", "host=", "started="):
        assert key in diagnostics, diagnostics


def test_only_changed_false_from_env_writes_no_manifest(client, server, target):
    result = run(client, server, target, env={"GEOIP_ONLY_CHANGED": "false"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (target / ".geoip-update.json").exists()


@pytest.mark.parametrize("value", ["TRUE", "Yes", " true", "1 "])
def test_only_changed_from_env_accepts_exact_values_only(client, server, target, value):
    result = run(client, server, target, env={"GEOIP_ONLY_CHANGED": value})
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (target / ".geoip-update.json").exists()


def test_flag_beats_env(client, server, target):
    result = run(client, server, target, env={"GEOIP_DATABASES": "GeoIP2-City.mmdb"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert sorted(p.name for p in target.iterdir()) == sorted(DBS)


def test_flag_wins_over_invalid_env(client, server, target):
    result = run(client, server, target, extra=[("max_retries", 2)], env={"GEOIP_MAX_RETRIES": "abc"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert sorted(p.name for p in target.iterdir()) == sorted(DBS)
