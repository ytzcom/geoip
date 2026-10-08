from clients import REPO


def test_cron_and_k8s_use_the_python_client():
    for flavour in ("python-cron", "python-k8s"):
        for name in ("geoip-update.py", "requirements.txt"):
            link = REPO / "cli" / flavour / name
            assert link.is_symlink(), link
            assert link.resolve() == (REPO / "cli/python" / name).resolve(), link
