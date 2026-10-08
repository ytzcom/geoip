import builtins
import importlib.util

import pytest

from clients import REPO


@pytest.fixture
def module(monkeypatch):
    spec = importlib.util.spec_from_file_location("geoip_update", REPO / "cli/python/geoip-update.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    monkeypatch.setattr(mod.time, "sleep", lambda seconds: None)
    return mod


def _failing_open(errors):
    def fake_open(*args, **kwargs):
        if errors:
            raise errors.pop(0)
        return builtins.open(*args, **kwargs)
    return fake_open


class _WindowsError(PermissionError):
    def __init__(self, winerror):
        super().__init__(13, "Permission denied")
        self.winerror = winerror


@pytest.mark.parametrize("winerror", [32, 33])
def test_sharing_violation_on_open_waits_then_locks(module, monkeypatch, tmp_path, winerror):
    path = tmp_path / "lock"
    errors = [_WindowsError(winerror), _WindowsError(winerror)]
    monkeypatch.setattr(module, "open", _failing_open(errors), raising=False)
    with module.SharedLock(path, 5):
        assert errors == []
        assert "pid=" in path.read_text()


def test_sharing_violation_on_open_times_out_with_message(module, monkeypatch, tmp_path, caplog):
    path = tmp_path / "lock"
    monkeypatch.setattr(module, "open", _failing_open([_WindowsError(32)] * 10), raising=False)
    with pytest.raises(SystemExit) as exit_info:
        with module.SharedLock(path, 2):
            pass
    assert exit_info.value.code == 1
    assert f"Timed out after 2 s waiting for lock {path}" in caplog.text


def test_other_open_error_fails_immediately(module, monkeypatch, tmp_path, caplog):
    path = tmp_path / "lock"
    errors = [PermissionError(13, "Permission denied")] + [_WindowsError(32)] * 10
    monkeypatch.setattr(module, "open", _failing_open(errors), raising=False)
    with pytest.raises(SystemExit) as exit_info:
        with module.SharedLock(path, 5):
            pass
    assert exit_info.value.code == 1
    assert len(errors) == 10
    assert f"Cannot open lock file {path}" in caplog.text
