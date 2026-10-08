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
