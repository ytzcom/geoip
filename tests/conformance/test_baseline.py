import pytest

from clients import run, start, flag
from conftest import DBS, wait_for_bytes
from fake_server import fixture_bytes

EXPECTED_SECOND_RUN = {
    "bash": "fails",
    "python": "fails",
    "go": "succeeds",
    "powershell": "fails",
}

PARTIAL_FAILURE_EXIT = {"powershell": 2, "bash": 22}


def test_default_run_downloads_every_requested_file(client, server, target):
    result = run(client, server, target)
    assert result.returncode == 0, result.stdout + result.stderr
    for name in DBS:
        assert (target / name).read_bytes() == fixture_bytes(name)


def test_default_run_leaves_no_manifest_and_no_part_files(client, server, target):
    result = run(client, server, target)
    assert result.returncode == 0, result.stdout + result.stderr
    leftovers = sorted(p.name for p in target.iterdir() if p.name not in DBS)
    assert leftovers == []


def test_partial_failure_keeps_successes_with_todays_exit_code(client, server, target):
    server.fail("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN", 500)
    result = run(client, server, target, extra=[("max_retries", 1)])
    assert result.returncode == PARTIAL_FAILURE_EXIT.get(client, 1), result.stdout + result.stderr
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
    assert not (target / "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN").exists()


def test_default_concurrent_run_behaviour_is_unchanged(client, server, target):
    if client.startswith("posix"):
        pytest.skip("no lock: concurrent runs race on <name>.part; behaviour is not deterministic today")
    server.slow("GeoIP2-City.mmdb", 6)
    databases = ["GeoIP2-City.mmdb"] if client == "powershell" else DBS
    first = start(client, server, target, databases=databases)
    wait_for_bytes(server, "GeoIP2-City.mmdb", first)
    second = run(client, server, target, databases=databases)
    first_output, _ = first.communicate(timeout=120)
    assert first.returncode == 0, first_output
    outcome = "succeeds" if second.returncode == 0 else "fails"
    assert outcome == EXPECTED_SECOND_RUN[client], second.stdout + second.stderr


def test_powershell_single_database_baseline(server, target):
    result = run("powershell", server, target, databases=["GeoIP2-City.mmdb"])
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
    assert sorted(p.name for p in target.iterdir()) == ["GeoIP2-City.mmdb"]


TIMEOUT_OUTCOME = {
    ("0", "powershell"): 2,
    ("1.5", "python"): 2,
    ("1.5", "go"): 2,
}


def _timeout_run(client, server, target, value):
    databases = ["GeoIP2-City.mmdb"] if client == "powershell" else list(DBS)
    result = run(client, server, target, databases=databases, extra=[("timeout", value)])
    expected = TIMEOUT_OUTCOME.get((value, client), 0)
    assert result.returncode == expected, result.stdout + result.stderr
    present = sorted(p.name for p in target.iterdir())
    assert present == (sorted(databases) if expected == 0 else []), present
    for name in present:
        assert (target / name).read_bytes() == fixture_bytes(name)


def test_timeout_zero_is_unchanged(client, server, target):
    _timeout_run(client, server, target, "0")


def test_decimal_timeout_is_unchanged(client, server, target):
    _timeout_run(client, server, target, "1.5")


@pytest.mark.parametrize("value", [".5", "1e1"])
@pytest.mark.parametrize("posix_client", ["posix-dash", "posix-busybox"])
def test_unusual_timeout_is_unchanged(posix_client, server, target, value):
    _timeout_run(posix_client, server, target, value)
