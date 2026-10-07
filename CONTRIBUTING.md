# Contributing

Thanks for helping. Read [AGENTS.md](AGENTS.md) first: it lists the commands,
architecture and the few rules that matter (no transcripts in logs, no
third-party code in the app).

## App

```sh
brew install xcodegen
cd app
xcodegen generate
xcodebuild -project TalkToMe.xcodeproj -scheme TalkToMe -derivedDataPath build test
./install.sh   # build Release, install to /Applications, launch
```

### Signing and permissions

By default the app is ad-hoc signed with the bundle ID `dev.talktome.TalkToMe`.
macOS ties Input Monitoring, Microphone and Accessibility permissions to the
signature, so with ad-hoc signing you will be asked again after each rebuild.

To keep permissions across builds, sign with your own Apple Development identity:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
security find-identity -p codesigning -v   # shows "Apple Development: you (TEAMID)"
# edit Local.xcconfig: your bundle ID and team ID
```

`Local.xcconfig` is git-ignored.

### Checking UI changes

The app can render every screen with sample data, no hotkey or permissions needed:

```sh
build/Build/Products/Debug/TalkToMe.app/Contents/MacOS/TalkToMe --snapshot /tmp/talktome-snapshots
```

If your change is visible in the README, regenerate `docs/images` the same way.

### Testing an engine without speaking

```sh
say -o /tmp/hello.aiff "Hello from the command line"
build/Build/Products/Debug/TalkToMe.app/Contents/MacOS/TalkToMe --transcribe /tmp/hello.aiff -engine apple
```

## Server

```sh
cd server
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'        # add ,mlx on Apple Silicon to run the model
.venv/bin/pytest
.venv/bin/ruff check . && .venv/bin/ruff format --check .
```

The tests use a fake engine, so they run anywhere without downloading a model.

## Pull requests

- One topic per pull request, with a short description of what and why.
- Tests for logic changes (`HotkeyStateMachine`, encoding, server endpoints).
- Snapshots attached for UI changes.
