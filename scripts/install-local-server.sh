#!/bin/bash
# Install talktome-server on this Mac and run it at login, on localhost only.
# TalkToMe runs this from Settings; it works by hand too:
#
#   scripts/install-local-server.sh 0.3.2
#
# Everything goes into one folder: a private Python (pinned and checksum-
# verified, so Homebrew upgrades cannot break it), a virtual environment, and
# the server from that release's source archive. Running it again updates the
# server. The first start downloads the model (about 2.5 GB) into the Hugging
# Face cache.
#
# Progress for the app goes to stdout ("step <name>"); everything else to
# stderr. On SIGTERM (Cancel in the app) it stops the running step at once.
#
# Environment:
#   TALKTOME_SERVER_HOME    install folder, ending in /talktome-server
#                           (default ~/.local/share/talktome-server)
#   TALKTOME_SERVER_SOURCE  pip requirement to install instead of the release
#   TALKTOME_NO_AGENT=1     install, but do not start the server
set -euo pipefail

version="${1:?usage: install-local-server.sh <version>}"
home="${TALKTOME_SERVER_HOME:-$HOME/.local/share/talktome-server}"
# The script replaces folders inside $home: never let an override point it elsewhere.
case "$home" in
  /*/talktome-server) ;;
  *) echo "TALKTOME_SERVER_HOME must be an absolute path ending in /talktome-server" >&2; exit 1 ;;
esac
venv="$home/venv"
release="https://github.com/freibergergarcia/talktome/archive/refs/tags/v$version.tar.gz#subdirectory=server"
source="${TALKTOME_SERVER_SOURCE:-talktome-server[mlx] @ $release}"

# python-build-standalone by Astral: a relocatable CPython for Apple Silicon.
python_version=3.12.15
python_url="https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-$python_version%2B20261003-aarch64-apple-darwin-install_only.tar.gz"
python_sha256=316a463172740e71d8dca1f2730784e325f3f720941137b5d674d5801a632213

# Progress on fd 3, the app's pipe. Commands get neither it nor stdout, so a
# straggler cannot keep the pipe open after the script ends.
exec 3>&1 1>&2
step() { echo "step $1" >&3; }

# A venv made from another Python is rebuilt, but the old one is kept until
# the new one works: venvs cannot be moved, so it goes aside and comes back
# if anything stops the rebuild (a failure, Cancel, or an earlier run that
# never finished).
restore_venv() {
  if [ -d "$venv.previous" ]; then
    rm -rf "$venv"
    mv "$venv.previous" "$venv"
  fi
}

# Each step runs in the background while the script waits: bash runs a TERM
# trap during `wait`, but only after a foreground command has finished.
child=
trap '[ -n "$child" ] && kill "$child" 2>/dev/null; restore_venv; exit 143' TERM INT
run() {
  "$@" 3>&- &
  child=$!
  local status=0
  wait "$child" || status=$?
  child=
  return "$status"
}

if [ "$(uname -m)" != arm64 ]; then
  echo "talktome-server needs a Mac with Apple Silicon."
  exit 1
fi
mkdir -p "$home"

step python
if [ "$("$home/python/bin/python3" -c 'import platform; print(platform.python_version())' 2>/dev/null)" != "$python_version" ]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  run curl -fsSL --retry 3 -o "$work/python.tar.gz" "$python_url"
  echo "$python_sha256  $work/python.tar.gz" | shasum -a 256 -c -
  run tar -xzf "$work/python.tar.gz" -C "$work" # unpacks into python/
  rm -rf "$home/python"
  mv "$work/python" "$home/python"
fi

step packages
restore_venv
if ! { grep -Fqx "home = $home/python/bin" "$venv/pyvenv.cfg" &&
       grep -Fqx "version = $python_version" "$venv/pyvenv.cfg"; } 2>/dev/null; then
  if [ -d "$venv" ]; then mv "$venv" "$venv.previous"; fi
  run "$home/python/bin/python3" -m venv "$venv" || { restore_venv; exit 1; }
fi
run "$venv/bin/pip" install --quiet --disable-pip-version-check --upgrade "$source" || { restore_venv; exit 1; }
rm -rf "$venv.previous"

step agent
if [ -z "${TALKTOME_NO_AGENT:-}" ]; then
  run "$venv/bin/talktome-server" install-agent
fi
step done
