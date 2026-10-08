from clients import run
from conftest import DBS
from fake_server import fixture_bytes
import manifest

M = ".geoip-update.json"


def _ok(result):
    assert result.returncode == 0, result.stdout + result.stderr


def test_first_run_downloads_and_writes_the_canonical_manifest(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    text = (target / M).read_text()
    expected = {n: {"etag": server.files[n].etag, "last_modified": server.files[n].last_modified, "size": len(server.files[n].data)} for n in DBS}
    assert text == manifest.canonical(expected)
    for n in DBS:
        assert (target / n).read_bytes() == fixture_bytes(n)


def test_second_run_downloads_nothing_and_logs_unchanged(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    server.reset_stats()
    result = run(client, server, target, extra=["only_changed"])
    _ok(result)
    for n in DBS:
        assert server.stats(n)["full"] == 0
        assert server.stats(n)["not_modified"] == 1
        assert f"Unchanged: {n}" in result.stdout + result.stderr


def test_only_the_changed_file_downloads(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    server.put("GeoIP2-City.mmdb", fixture_bytes("GeoIP2-City.mmdb", "v2"))
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed"]))
    assert server.stats("GeoIP2-City.mmdb")["full"] == 1
    assert server.stats("IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")["full"] == 0
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb", "v2")
    assert manifest.read(target / M)["GeoIP2-City.mmdb"]["etag"] == server.files["GeoIP2-City.mmdb"].etag


def test_wrong_size_or_missing_file_downloads_again(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    (target / "GeoIP2-City.mmdb").write_bytes(b"truncated")
    (target / "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN").unlink()
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed"]))
    for n in DBS:
        assert server.stats(n)["full"] == 1
        assert (target / n).read_bytes() == fixture_bytes(n)


def test_force_downloads_everything(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed", "force"]))
    for n in DBS:
        assert server.stats(n)["full"] == 1


def test_corrupt_manifest_is_treated_as_absent(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    (target / M).write_text("{ not json")
    server.reset_stats()
    _ok(run(client, server, target, extra=["only_changed"]))
    for n in DBS:
        assert server.stats(n)["full"] == 1
    assert set(manifest.read(target / M)) == set(DBS)


def test_object_changing_mid_download_restarts_the_file(client, server, target):
    new = fixture_bytes("GeoIP2-City.mmdb", "v3")
    server.change_during_download("GeoIP2-City.mmdb", new, after_bytes=50_000)
    _ok(run(client, server, target, extra=["only_changed"]))
    assert (target / "GeoIP2-City.mmdb").read_bytes() == new
    assert manifest.read(target / M)["GeoIP2-City.mmdb"]["etag"] == server.files["GeoIP2-City.mmdb"].etag


def test_entries_for_unrequested_files_are_kept(client, server, target):
    _ok(run(client, server, target, extra=["only_changed"]))
    _ok(run(client, server, target, databases=["GeoIP2-City.mmdb"], extra=["only_changed"]))
    assert set(manifest.read(target / M)) == set(DBS)


def test_stale_part_file_still_ends_with_a_complete_file(client, server, target):
    (target / "GeoIP2-City.mmdb.part").write_bytes(b"garbage from a killed run")
    _ok(run(client, server, target, extra=["only_changed"]))
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
