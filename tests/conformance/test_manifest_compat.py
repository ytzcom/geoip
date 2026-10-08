import itertools

import pytest

from clients import CLIENTS, available, run
from conftest import DBS
from fake_server import fixture_bytes
import manifest

M = ".geoip-update.json"
PREFIXED = "GeoIP2-City.mmdb.extra"
NAMES = (*DBS, PREFIXED)


@pytest.fixture
def prefixed_server(server):
    server.put(PREFIXED, fixture_bytes(PREFIXED))
    return server


def _ok(result):
    assert result.returncode == 0, result.stdout + result.stderr


def test_prefixed_name_orders_differently_by_name_and_by_line():
    assert sorted(NAMES) != [line.split("|")[0] for line in sorted(n + "|" for n in NAMES)]


@pytest.mark.parametrize("writer,reader", list(itertools.permutations(CLIENTS, 2)))
def test_manifest_written_by_one_client_is_read_by_another(writer, reader, prefixed_server, target):
    server = prefixed_server
    _ok(run(writer, server, target, databases=NAMES, extra=["only_changed"]))
    written = (target / M).read_bytes()
    server.reset_stats()
    result = run(reader, server, target, databases=NAMES, extra=["only_changed"])
    _ok(result)
    for n in NAMES:
        assert server.stats(n)["full"] == 0
        assert server.stats(n)["not_modified"] == 1
        assert f"Unchanged: {n}" in result.stdout + result.stderr
    assert (target / M).read_bytes() == written


def test_every_client_writes_a_byte_identical_manifest(prefixed_server, tmp_path):
    server = prefixed_server
    expected = manifest.canonical({n: {"etag": server.files[n].etag, "last_modified": server.files[n].last_modified, "size": len(server.files[n].data)} for n in NAMES})
    for c in CLIENTS:
        assert available(c), f"{c} is not installed in the test image"
        target = tmp_path / c
        target.mkdir()
        _ok(run(c, server, target, databases=NAMES, extra=["only_changed"]))
        assert (target / M).read_text() == expected, c
