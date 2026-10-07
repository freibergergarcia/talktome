#!/bin/bash
# Install or update talktome-server on another Mac over SSH and run it at login.
#
#   scripts/deploy-server.sh <ssh-host> [--host 0.0.0.0] [--port 8766] [--model ...]
#
# Environment:
#   PYTHON   interpreter on the remote Mac, 3.10+ (default: python3)
#   HF_HOME  remote Hugging Face cache to reuse (default: the standard cache)
#
# Extra arguments go to `talktome-server install-agent`. Without --host the
# server only listens on the remote machine itself.
set -euo pipefail
cd "$(dirname "$0")/.."

remote="${1:?usage: scripts/deploy-server.sh <ssh-host> [install-agent options]}"
shift
dir='~/.local/share/talktome-server'
python="${PYTHON:-python3}"
hf_home="${HF_HOME:-}"

ssh "$remote" "mkdir -p $dir"
rsync -a --delete --exclude .venv --exclude __pycache__ --exclude '*.egg-info' server/ "$remote:$dir/src/"
ssh "$remote" bash -s -- "$python" "$hf_home" "$@" <<'REMOTE'
set -euo pipefail
python="$1"; hf_home="$2"; shift 2
cd ~/.local/share/talktome-server
[ -x venv/bin/python ] || "$python" -m venv venv
venv/bin/pip install -q --upgrade pip
venv/bin/pip install -q "./src[mlx]"
if [ -n "$hf_home" ]; then export HF_HOME="$hf_home"; fi
venv/bin/talktome-server install-agent "$@"
REMOTE
