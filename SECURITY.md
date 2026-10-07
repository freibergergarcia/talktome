# Security

## What TalkToMe sends where

| Engine | Network traffic |
|---|---|
| On this Mac | None |
| Server | The recorded clip (WAV) to the configured URL, with the API key as a bearer token |

The app never sends audio anywhere you did not configure. When the server is
unreachable and fallback is on, it transcribes on-device instead.

## talktome-server

- Listens on `127.0.0.1` by default. Listening on the network (`--host 0.0.0.0`)
  requires a bearer token; the server refuses to start without one.
- The token is 32 random bytes, stored in `~/.config/talktome/token` with
  mode `0600`, and compared in constant time.
- `/health` is unauthenticated so clients can check reachability. It returns
  only `{"ok": true}`. Every other path, including the API docs, needs the
  token, and the token and upload size are checked before the request body is
  read, so an unauthenticated client cannot make the server store data.
- **Traffic is plain HTTP.** On a trusted home network that is a reasonable
  trade-off; on shared networks, put the server behind HTTPS (a reverse proxy
  or a tunnel such as Tailscale). The app allows plain HTTP only to local
  addresses (`.local` names and private IPs); anything else must be HTTPS.
- Transcripts are never logged. The log records clip length, loudness and timing.

## The app

- The API key is stored in the macOS Keychain.
- The hotkey uses a listen-only event tap: it can observe key events but not
  modify them. Pasting posts a single ⌘V and needs Accessibility permission,
  which you can avoid by turning off "Paste at the cursor".
- No transcript is written to disk. Stats store counts only.

## Reporting a vulnerability

Please open a private security advisory on the repository rather than a public
issue. Include steps to reproduce and the versions involved.
