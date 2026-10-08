from clients import run
from fake_server import fixture_bytes
from test_baseline import PARTIAL_FAILURE_EXIT

CITY = "GeoIP2-City.mmdb"


def test_transient_download_error_is_retried(client, server, target):
    server.fail_times(CITY, 1)
    result = run(client, server, target)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / CITY).read_bytes() == fixture_bytes(CITY)
    assert server.stats(CITY)["attempts"] >= 2


def test_object_change_mid_download_never_yields_a_mixed_file(client, server, target):
    v1 = fixture_bytes(CITY)
    v2 = fixture_bytes(CITY, "v2")
    server.change_during_download(CITY, v2, after_bytes=50_000)
    result = run(client, server, target)
    if (target / CITY).exists():
        assert (target / CITY).read_bytes() in (v1, v2), "mixed file"
    assert sorted(p.name for p in target.iterdir() if p.name.endswith(".part")) == []
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / CITY).read_bytes() == v2


def test_final_failure_removes_part(client, server, target):
    server.fail(CITY, 500)
    result = run(client, server, target, extra=[("max_retries", 1)])
    assert result.returncode == PARTIAL_FAILURE_EXIT.get(client, 1), result.stdout + result.stderr
    assert not (target / f"{CITY}.part").exists()
