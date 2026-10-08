from clients import run, run_powershell_file, start
from conftest import DBS, wait_for_bytes
from fake_server import fixture_bytes
import manifest

CITY, PROXY = DBS


def test_file_invocation_splits_comma_separated_databases(server, target):
    result = run_powershell_file(server, target, DBS)
    assert result.returncode == 0, result.stdout + result.stderr
    for name in DBS:
        assert (target / name).read_bytes() == fixture_bytes(name)


def test_quiet_partial_failure_keeps_the_exit_code(server, target):
    server.fail(PROXY, 500)
    result = run("powershell", server, target, extra=["quiet", ("max_retries", 1)])
    assert result.returncode == 2, result.stdout + result.stderr
    assert sorted(p.name for p in target.iterdir()) == [CITY]
    assert (target / CITY).read_bytes() == fixture_bytes(CITY)


def test_quiet_lock_timeout_exits_1(server, target):
    lock = str(target / ".geoip-update.lock")
    server.slow(CITY, 8)
    first = start("powershell", server, target, extra=[("lock_file", lock)])
    wait_for_bytes(server, CITY, first)
    second = run("powershell", server, target, extra=["quiet", ("lock_file", lock), ("lock_timeout", 1)])
    first_output, _ = first.communicate(timeout=120)
    assert first.returncode == 0, first_output
    assert second.returncode == 1, second.stdout + second.stderr
    assert f"Timed out after 1 s waiting for lock {lock}" in second.stdout + second.stderr


def test_quiet_only_changed_records_successes_despite_a_failure(server, target):
    server.fail(PROXY, 500)
    result = run("powershell", server, target, extra=["quiet", "only_changed", ("max_retries", 1)])
    assert result.returncode == 2, result.stdout + result.stderr
    f = server.files[CITY]
    assert (target / ".geoip-update.json").read_text() == manifest.canonical({CITY: {"etag": f.etag, "last_modified": f.last_modified, "size": len(f.data)}})
