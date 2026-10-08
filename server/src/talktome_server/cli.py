"""talktome-server command line.

talktome-server serve                 run in the foreground (localhost only)
talktome-server serve --host 0.0.0.0  listen on the network (needs a token)
talktome-server token                 print the token, creating it if needed
talktome-server install-agent         run at login via launchd (macOS)
talktome-server uninstall-agent       stop it and remove the launch agent
"""

import argparse
import ipaddress
import logging
import os
import plistlib
import secrets
import subprocess
import sys
import time
from pathlib import Path

from .engine import DEFAULT_MODEL
from .languages import parse_languages

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "talktome"
TOKEN_FILE = CONFIG_DIR / "token"
AGENT_LABEL = "com.talktome.server"
AGENT_PLIST = Path.home() / "Library/LaunchAgents" / f"{AGENT_LABEL}.plist"
AGENT_LOG = Path.home() / "Library/Logs/talktome-server.log"
DEFAULT_PORT = 8766


def is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def read_token() -> str | None:
    if token := os.environ.get("TALKTOME_TOKEN"):
        return token.strip()
    if TOKEN_FILE.exists():
        # Older versions, or a hand-made file, may have left it readable by others.
        if TOKEN_FILE.stat().st_mode & 0o077:
            TOKEN_FILE.chmod(0o600)
        return TOKEN_FILE.read_text().strip() or None
    return None


def ensure_token() -> str:
    if token := read_token():
        return token
    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    token = secrets.token_hex(32)
    TOKEN_FILE.touch(mode=0o600)
    TOKEN_FILE.chmod(0o600)  # touch keeps the mode of a file that already existed (e.g. empty)
    TOKEN_FILE.write_text(token + "\n")
    return token


def cmd_serve(args: argparse.Namespace) -> None:
    import uvicorn

    from .app import create_app
    from .engine import ParakeetEngine

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    token = read_token()
    if not is_loopback(args.host) and not token:
        sys.exit(
            f"Refusing to listen on {args.host} without a token.\n"
            "Run `talktome-server token` to create one, then start again."
        )
    if not token:
        logging.warning("no token set: any process on this machine can use the server")

    engine = ParakeetEngine(args.model, languages=parse_languages(args.languages))
    engine.warm_up()
    uvicorn.run(create_app(engine, token), host=args.host, port=args.port, log_level="warning")


def cmd_token(_: argparse.Namespace) -> None:
    print(ensure_token())


def launchctl(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True, check=check)


def unload_agent() -> None:
    domain = f"gui/{os.getuid()}"
    launchctl("bootout", f"{domain}/{AGENT_LABEL}")
    # bootout returns before the job is gone; bootstrapping too early fails.
    for _ in range(20):
        if launchctl("print", f"{domain}/{AGENT_LABEL}").returncode != 0:
            return
        time.sleep(0.5)


def cmd_install_agent(args: argparse.Namespace) -> None:
    if sys.platform != "darwin":
        sys.exit("install-agent uses launchd and only works on macOS.")
    if not is_loopback(args.host):
        ensure_token()

    env = {}
    # Reuse an existing Hugging Face cache instead of downloading the model again.
    if hf_home := os.environ.get("HF_HOME"):
        env["HF_HOME"] = hf_home

    plist = {
        "Label": AGENT_LABEL,
        "ProgramArguments": [
            sys.executable,
            "-m",
            "talktome_server",
            "serve",
            "--host",
            args.host,
            "--port",
            str(args.port),
            "--model",
            args.model,
            *(["--languages", args.languages] if args.languages else []),
        ],
        "EnvironmentVariables": env,
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "StandardOutPath": str(AGENT_LOG),
        "StandardErrorPath": str(AGENT_LOG),
    }
    AGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)
    AGENT_LOG.parent.mkdir(parents=True, exist_ok=True)
    unload_agent()
    with AGENT_PLIST.open("wb") as handle:
        plistlib.dump(plist, handle)
    launchctl("bootstrap", f"gui/{os.getuid()}", str(AGENT_PLIST), check=True)

    print(f"Installed {AGENT_PLIST}")
    print(f"Listening on {args.host}:{args.port} once the model has loaded. Log: {AGENT_LOG}")
    if not is_loopback(args.host):
        print("\nmacOS may block incoming connections to Python. If other machines cannot connect,")
        print("allow this interpreter in the firewall (see the README, 'Firewall').")
        print(f"Program to allow: {firewall_target()}")


def firewall_target() -> Path:
    """The binary macOS's firewall sees. Framework builds of Python (Homebrew,
    python.org) re-exec into an inner Python.app, so that is what to allow."""
    app = Path(sys.base_prefix) / "Resources/Python.app"
    return app.resolve() if app.exists() else Path(sys.executable).resolve()


def cmd_uninstall_agent(_: argparse.Namespace) -> None:
    unload_agent()
    if AGENT_PLIST.exists():
        AGENT_PLIST.unlink()
        print(f"Removed {AGENT_PLIST}")
    else:
        print("No launch agent installed.")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="talktome-server", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_listen_options(p: argparse.ArgumentParser) -> None:
        p.add_argument("--host", default="127.0.0.1", help="address to listen on (default: 127.0.0.1)")
        p.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"port (default: {DEFAULT_PORT})")
        p.add_argument("--model", default=DEFAULT_MODEL, help=f"Hugging Face model id (default: {DEFAULT_MODEL})")
        p.add_argument(
            "--languages",
            help="languages spoken, e.g. en,pt: rules out other alphabets unless a request names its own",
        )

    serve = sub.add_parser("serve", help="run the server in the foreground")
    add_listen_options(serve)
    serve.set_defaults(func=cmd_serve)

    sub.add_parser("token", help="print the bearer token, creating it if needed").set_defaults(func=cmd_token)

    install = sub.add_parser("install-agent", help="run at login via launchd (macOS)")
    add_listen_options(install)
    install.set_defaults(func=cmd_install_agent)

    sub.add_parser("uninstall-agent", help="stop and remove the launch agent").set_defaults(func=cmd_uninstall_agent)

    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
