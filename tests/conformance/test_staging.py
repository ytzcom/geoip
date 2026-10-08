import threading
import time

from clients import start
from fake_server import fixture_bytes


def test_target_name_is_never_a_partial_file(client, server, target):
    old = fixture_bytes("GeoIP2-City.mmdb", "old")
    new = fixture_bytes("GeoIP2-City.mmdb")
    (target / "GeoIP2-City.mmdb").write_bytes(old)
    server.slow("GeoIP2-City.mmdb", 5)
    seen = set()
    stop = threading.Event()

    def watch():
        while not stop.is_set():
            if (target / "GeoIP2-City.mmdb.part").exists():
                seen.add("part_seen")
            try:
                data = (target / "GeoIP2-City.mmdb").read_bytes()
                seen.add("old" if data == old else "new" if data == new else "partial")
            except FileNotFoundError:
                seen.add("absent")
            time.sleep(0.05)

    t = threading.Thread(target=watch, daemon=True)
    t.start()
    try:
        proc = start(client, server, target, extra=[] if client.startswith("posix") else ["no_lock"])
        proc.communicate(timeout=120)
    finally:
        stop.set()
        t.join()
    assert "part_seen" in seen, seen
    assert "partial" not in seen, seen
    assert (target / "GeoIP2-City.mmdb").read_bytes() == new
