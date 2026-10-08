import subprocess

from clients import REPO, run, run_powershell_file, start
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


def test_decimal_timeout_from_env_matches_the_flag(server, tmp_path):
    results = {}
    for label, extra, env in (("flag", [("timeout", "1.5")], None), ("env", [], {"GEOIP_TIMEOUT": "1.5"})):
        directory = tmp_path / label
        directory.mkdir()
        results[label] = run("powershell", server, directory, databases=[CITY], extra=extra, env=env)
    assert results["flag"].returncode == 0, results["flag"].stdout + results["flag"].stderr
    assert results["env"].returncode == results["flag"].returncode, results["env"].stdout + results["env"].stderr


_BOM = b"\xef\xbb\xbf"


def _parse_errors(path):
    script = f"$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('{path}', [ref]$null, [ref]$e); $e.Count"
    result = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    return int(result.stdout.strip())


def test_script_is_utf8_with_bom_and_parses_as_utf8():
    script = REPO / "cli/geoip-update.ps1"
    assert script.read_bytes().startswith(_BOM)
    assert _parse_errors(script) == 0


def test_script_without_bom_misparses_as_ansi(tmp_path):
    data = (REPO / "cli/geoip-update.ps1").read_bytes()[len(_BOM):]
    as_ansi = tmp_path / "ansi.ps1"
    as_ansi.write_bytes(_BOM + data.decode("cp1252", errors="replace").encode("utf-8"))
    assert _parse_errors(as_ansi) > 0
