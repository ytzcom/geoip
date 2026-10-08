import subprocess
import time
from pathlib import Path

import pytest

from clients import CLIENTS, GO_BINARY, REPO, available
from fake_server import FakeServer, fixture_bytes

DBS = ("GeoIP2-City.mmdb", "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")


def wait_for_bytes(server, name, deadline=60):
    end = time.monotonic() + deadline
    while server.stats(name)["bytes"] == 0:
        if time.monotonic() >= end:
            raise TimeoutError(f"no bytes of {name} served within {deadline} s")
        time.sleep(0.05)


@pytest.fixture(scope="session", autouse=True)
def go_binary():
    subprocess.run(["go", "build", "-o", str(GO_BINARY), "."], cwd=REPO / "cli/go", check=True)
    return GO_BINARY


@pytest.fixture
def server():
    s = FakeServer()
    for name in DBS:
        s.put(name, fixture_bytes(name))
    yield s
    s.close()


@pytest.fixture
def target(tmp_path) -> Path:
    d = tmp_path / "geoip"
    d.mkdir()
    return d


@pytest.fixture(params=CLIENTS)
def client(request):
    if not available(request.param):
        pytest.fail(f"{request.param} is not installed in the test image")
    return request.param
