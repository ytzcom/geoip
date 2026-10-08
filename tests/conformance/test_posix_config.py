import subprocess

import pytest

from clients import _env, command

POSIX = ["posix-dash", "posix-busybox"]


def _run_with_config(client, server, target, config, extra):
    path = target.parent / "config.yaml"
    path.write_text(config)
    cmd = command(client, server, target, ("GeoIP2-City.mmdb",), extra) + ["--config", str(path)]
    return subprocess.run(cmd, capture_output=True, text=True, env=_env(None), timeout=120)


@pytest.mark.parametrize("client", POSIX)
def test_explicit_lock_timeout_equal_to_default_beats_yaml(client, server, target):
    result = _run_with_config(client, server, target, "lock_timeout: abc\n", [("lock_timeout", 1800)])
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("client", POSIX)
def test_explicit_empty_lock_file_beats_yaml(client, server, target):
    yaml_lock = target.parent / "yaml.lock"
    result = _run_with_config(client, server, target, f"lock_file: {yaml_lock}\n", [("lock_file", "")])
    assert result.returncode == 0, result.stdout + result.stderr
    assert not yaml_lock.exists()
    assert not (target.parent / "yaml.lock.d").exists()


@pytest.mark.parametrize("client", POSIX)
def test_yaml_lock_keys_apply_without_flags(client, server, target):
    yaml_lock = target.parent / "yaml.lock"
    result = _run_with_config(client, server, target, f"lock_file: {yaml_lock}\nlock_timeout: abc\n", [])
    assert result.returncode == 1
    assert "Invalid --lock-timeout/GEOIP_LOCK_TIMEOUT: 'abc'" in result.stdout + result.stderr


@pytest.mark.parametrize("client", POSIX)
def test_explicit_only_changed_with_yaml_only_changed(client, server, target):
    result = _run_with_config(client, server, target, "only_changed: true\n", ["only_changed"])
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / ".geoip-update.json").exists()


@pytest.mark.parametrize("client", POSIX)
def test_last_yaml_key_overridden_by_flag(client, server, target):
    result = _run_with_config(client, server, target, "api_key: from-yaml\n", [])
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / "GeoIP2-City.mmdb").exists()
