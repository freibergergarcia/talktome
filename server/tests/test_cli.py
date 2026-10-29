import plistlib

import pytest

from talktome_server import cli
from talktome_server.engine import DEFAULT_MODEL


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


def test_ensure_token_tightens_an_existing_empty_file(tmp_path, monkeypatch):
    monkeypatch.delenv("TALKTOME_TOKEN", raising=False)
    monkeypatch.setattr(cli, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cli, "TOKEN_FILE", tmp_path / "token")
    (tmp_path / "token").touch(mode=0o644)
    cli.ensure_token()
    assert (tmp_path / "token").stat().st_mode & 0o777 == 0o600


def test_env_token_wins(monkeypatch):
    monkeypatch.setenv("TALKTOME_TOKEN", " from-env ")
    assert cli.read_token() == "from-env"


def test_serve_refuses_network_without_token(tmp_path, monkeypatch):
    monkeypatch.delenv("TALKTOME_TOKEN", raising=False)
    monkeypatch.setattr(cli, "TOKEN_FILE", tmp_path / "missing")
    with pytest.raises(SystemExit, match="without a token"):
        cli.main(["serve", "--host", "0.0.0.0"])


def test_existing_readable_token_is_tightened(tmp_path, monkeypatch):
    monkeypatch.delenv("TALKTOME_TOKEN", raising=False)
    monkeypatch.setattr(cli, "TOKEN_FILE", tmp_path / "token")
    (tmp_path / "token").write_text("abc\n")
    (tmp_path / "token").chmod(0o644)
    assert cli.read_token() == "abc"
    assert (tmp_path / "token").stat().st_mode & 0o777 == 0o600


def test_nemotron_needs_a_model():
    with pytest.raises(SystemExit, match="needs --model"):
        cli.main(["serve", "--engine", "nemotron"])


def test_nemotron_needs_a_converted_folder(tmp_path, monkeypatch):
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    with pytest.raises(SystemExit, match="convert_nemotron.py first"):
        cli.main(["install-agent", "--engine", "nemotron", "--model", str(tmp_path / "missing")])


def test_nemotron_needs_its_extra(tmp_path, monkeypatch):
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    monkeypatch.setattr(cli, "nemotron_installed", lambda: False)
    with pytest.raises(SystemExit, match=r"talktome-server\[mlx,nemotron\]"):
        cli.main(["install-agent", "--engine", "nemotron", "--model", str(tmp_path)])


def installed_arguments(tmp_path, monkeypatch, *argv):
    """What install-agent writes after the interpreter: `-m talktome_server ...`."""
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    monkeypatch.setattr(cli, "AGENT_PLIST", tmp_path / "agent.plist")
    monkeypatch.setattr(cli, "AGENT_LOG", tmp_path / "server.log")
    monkeypatch.setattr(cli, "unload_agent", lambda: None)
    monkeypatch.setattr(cli, "launchctl", lambda *args, **kwargs: None)
    cli.main(["install-agent", *argv])
    with (tmp_path / "agent.plist").open("rb") as handle:
        return plistlib.load(handle)["ProgramArguments"][1:]


def test_install_agent_writes_the_same_arguments_for_parakeet(tmp_path, monkeypatch):
    assert installed_arguments(tmp_path, monkeypatch, "--languages", "en,pt") == [
        "-m", "talktome_server", "serve", "--host", "127.0.0.1", "--port", "8766",
        "--model", DEFAULT_MODEL, "--languages", "en,pt",
    ]  # fmt: skip


def test_install_agent_records_nemotron_and_an_absolute_folder(tmp_path, monkeypatch):
    (tmp_path / "nemotron-4bit").mkdir()
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(cli, "nemotron_installed", lambda: True)
    arguments = installed_arguments(tmp_path, monkeypatch, "--engine", "nemotron", "--model", "nemotron-4bit")
    assert arguments[-4:] == ["--engine", "nemotron", "--model", str(tmp_path.resolve() / "nemotron-4bit")]
