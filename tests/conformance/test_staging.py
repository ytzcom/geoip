import threading
import time

from clients import start
from fake_server import fixture_bytes


def test_target_name_is_never_a_partial_file(client, server, target):
    old = fixture_bytes("GeoIP2-City.mmdb", "old")
    (target / "GeoIP2-City.mmdb").write_bytes(old)
    server.slow("GeoIP2-City.mmdb", 5)
    seen = set()
    stop = threading.Event()

    def watch():
        while not stop.is_set():
            p = target / "GeoIP2-City.mmdb"
            if p.exists():
                data = p.read_bytes()
                seen.add("old" if data == old else "new" if data == fixture_bytes("GeoIP2-City.mmdb") else "partial")
            time.sleep(0.05)

    t = threading.Thread(target=watch)
    t.start()
    proc = start(client, server, target, extra=[] if client.startswith("posix") else ["no_lock"])
    proc.communicate(timeout=120)
    stop.set()
    t.join()
    assert "partial" not in seen
    assert (target / "GeoIP2-City.mmdb").read_bytes() == fixture_bytes("GeoIP2-City.mmdb")
