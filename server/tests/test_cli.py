import pytest

from talktome_server import cli


@pytest.mark.parametrize(
    "host,expected",
    [
        ("127.0.0.1", True),
        ("localhost", True),
        ("::1", True),
        ("0.0.0.0", False),
        ("192.168.1.20", False),
        ("example.local", False),
    ],
)
def test_is_loopback(host, expected):
    assert cli.is_loopback(host) is expected


def test_ensure_token_creates_private_file_once(tmp_path, monkeypatch):
    monkeypatch.delenv("TALKTOME_TOKEN", raising=False)
    monkeypatch.setattr(cli, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cli, "TOKEN_FILE", tmp_path / "token")
    first = cli.ensure_token()
    assert len(first) == 64
    assert (tmp_path / "token").stat().st_mode & 0o777 == 0o600
    assert cli.ensure_token() == first


def test_env_token_wins(monkeypatch):
    monkeypatch.setenv("TALKTOME_TOKEN", " from-env ")
    assert cli.read_token() == "from-env"


def test_serve_refuses_network_without_token(tmp_path, monkeypatch):
    monkeypatch.delenv("TALKTOME_TOKEN", raising=False)
    monkeypatch.setattr(cli, "TOKEN_FILE", tmp_path / "missing")
    with pytest.raises(SystemExit, match="without a token"):
        cli.main(["serve", "--host", "0.0.0.0"])
