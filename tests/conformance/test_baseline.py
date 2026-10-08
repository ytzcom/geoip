import time

import pytest

from clients import run, start, flag
from conftest import DBS
from fake_server import fixture_bytes

EXPECTED_SECOND_RUN = {
    "posix-dash": "fails",
    "posix-busybox": "fails",
    "bash": "fails",
    "python": "fails",
    "go": "succeeds",
    "powershell": "fails",
}

PARTIAL_FAILURE_EXIT = {"powershell": 2, "bash": 22}

PS_MULTI_DB_REASON = "ps1 line 799 [int]($urls.PSObject.Properties.Count) throws when /auth returns more than one database; fixed in Task 7"


def _xfail_powershell_multi_db(request, client):
    if client == "powershell":
        request.applymarker(pytest.mark.xfail(strict=True, reason=PS_MULTI_DB_REASON))


def test_default_run_downloads_every_requested_file(request, client, server, target):
    _xfail_powershell_multi_db(request, client)
    result = run(client, server, target)
    assert result.returncode == 0, result.stdout + result.stderr
    for name in DBS:
        assert (target / name).read_bytes() == fixture_bytes(name)


def test_default_run_leaves_no_manifest_and_no_part_files(client, server, target):
    run(client, server, target)
    leftovers = sorted(p.name for p in target.iterdir() if p.name not in DBS)
    assert leftovers == []


def test_partial_failure_keeps_successes_with_todays_exit_code(request, client, server, target):
    _xfail_powershell_multi_db(request, client)
    server.fail("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN", 500)
    result = run(client, server, target, extra=[("max_retries", 1)])
    assert result.returncode == PARTIAL_FAILURE_EXIT.get(client, 1), result.stdout + result.stderr
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
    assert not (target / "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN").exists()


def test_default_lock_behaviour_is_unchanged(client, server, target):
    server.slow("GeoIP2-City.mmdb", 6)
    databases = ["GeoIP2-City.mmdb"] if client == "powershell" else DBS
    first = start(client, server, target, databases=databases)
    time.sleep(2)
    second = run(client, server, target, databases=databases)
    first.wait(timeout=120)
    outcome = "succeeds" if second.returncode == 0 else "fails"
    assert outcome == EXPECTED_SECOND_RUN[client], second.stdout + second.stderr


def test_powershell_single_database_baseline(server, target):
    result = run("powershell", server, target, databases=["GeoIP2-City.mmdb"])
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
    assert sorted(p.name for p in target.iterdir()) == ["GeoIP2-City.mmdb"]
