from clients import run_powershell_file
from conftest import DBS
from fake_server import fixture_bytes


def test_file_invocation_splits_comma_separated_databases(server, target):
    result = run_powershell_file(server, target, DBS)
    assert result.returncode == 0, result.stdout + result.stderr
    for name in DBS:
        assert (target / name).read_bytes() == fixture_bytes(name)
