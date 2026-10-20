# Development

How to build Stop Please, talk to its helper, run the tests, and read its logs. For what the app does and how it works, see the [README](README.md).

---

## Building

Requirements:

- Xcode 16.4 or later (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated from `project.yml` and is not committed. Edit `project.yml`, not the project:

```text
xcodegen generate
xcodebuild -project StopPlease.xcodeproj -scheme StopPlease -derivedDataPath .build/DerivedData build
```

The app is at:

```text
.build/DerivedData/Build/Products/Debug/StopPlease.app
```

Opening `StopPlease.xcodeproj` in Xcode works too, but run `xcodegen generate` again after changing `project.yml` or adding files.

### Signing

Builds are signed ad-hoc by default, so the project builds without an Apple account. An ad-hoc signature changes with every build, and macOS then stops honoring the app's Accessibility permission. To keep the permission across rebuilds, sign with your own identity: create `Local.xcconfig` next to `Signing.xcconfig` (it is gitignored) containing:

```text
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <your team ID>
```

Then run `xcodegen generate` again.

---

## The helper

The helper is a library loaded into `/usr/bin/perl` that serves one JSON request per line on stdin and answers one JSON line per request on stdout. The app starts one helper and keeps it running.

To talk to it by hand, start it from a built app:

```text
APP="$PWD/.build/DerivedData/Build/Products/Debug/StopPlease.app"
/usr/bin/perl "$APP/Contents/Resources/perl_helper.pl" "$APP/Contents/Frameworks/libNowPlayingPerlHelper.dylib"
```

- Use `/usr/bin/perl`, not a Homebrew Perl: only Apple's Perl has the identity that sees other apps' sources.
- The library path must be absolute; the system Perl refuses relative paths.
- Closing stdin (Ctrl-D) ends the helper.

The helper first prints `{"event":"ready",…}`, or `{"event":"fatal",…}` and exits if MediaRemote has changed in a way it cannot use.

### Listing sources

A `list` only reads; nothing is sent to any app.

```jsonc
→ {"id":1,"op":"list"}
← {"id":1,"ok":true,
   "current":{"pid":1234,"clientBundle":"com.spotify.client"},
   "sources":[{"pid":1234,"clientBundle":"com.spotify.client",
               "appBundle":"com.spotify.client","appName":"Spotify",
               "state":"Playing","title":"Song Title"}]}
```

### Commands

A `command` plays or pauses one or more sources, each identified by `pid` and `clientBundle` from a `list`. It controls real players.

```jsonc
→ {"id":2,"op":"command","action":"pause",
   "targets":[{"pid":1234,"clientBundle":"com.spotify.client"}]}
← {"id":2,"ok":true,"results":[
     {"pid":1234,"outcome":"done","route":"direct","state":"Paused"}]}
```

| Outcome | Meaning |
| ------- | ------- |
| `done` | Sent, and the source reached the expected state |
| `skipped` | Not in the state the action needs (for example, `play` on a source that is not Paused); nothing sent |
| `notFound` | No source with that `pid` and `clientBundle`, for example because the app quit |
| `ambiguousBundle` | Another listed source has the same `clientBundle`; nothing sent |
| `overrideNotHonored` | The target did not become the Now Playing app within 1 s; nothing sent |
| `noStateChange` | Sent, but the state did not change in time |

`route` is `direct` when the target was already the Now Playing app and `override` otherwise. Use `outcome`, not `route`, to tell whether anything was sent.

A failed request has `"ok":false` and an error code: `badRequest`, `timeout` (mediaremoted did not answer within 8 s), or `mediaRemoteError`. A failed `command` sent nothing.

---

## Tests

### Acceptance tests

```text
python3 -I tests/perl_acceptance.py
```

> **This plays and pauses your media.** Spotify, Zen, and YouTube Music must be open with media loaded. `--test-g` also quits YouTube Music.

The script builds the helper library into `.build/`, starts one helper, and runs through it:

- **Test H**: three alternating pause/play cycles on each app
- **Test E**: each app keeps its identity across relisting, play/pause, and changes of the Now Playing app
- **Test F**: pause everything playing as one group, resume Spotify and Zen, then YouTube Music
- **Test G** (with `--test-g`): a paused app quits before its group resumes

Every request and reply is saved under `Outputs/ACCEPTANCE_<timestamp>/`. States are as reported by MediaRemote; whether you actually heard each change is up to you.

### Smoke test

```text
python3 -I tests/helper_smoke.py .build/DerivedData/Build/Products/Debug/StopPlease.app
```

Starts the helper bundled in a built app the same way the app does, checks that it reports `ready`, and sends one `list`. It only reads, so it is safe to run while media plays and next to the running app.

---

## Logs

The app logs to the unified log under the subsystem `com.andrecheng.StopPlease`:

```text
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.andrecheng.StopPlease"'
```

Use the full path: in zsh, `log` is a shell builtin.

| Category | Logs |
| -------- | ---- |
| `helper` | helper start, ready, exit, and restart |
| `coordinator` | one line per command with each app's outcome and state; groups saved, removed, or kept for retry |
| `shortcut` | the chosen and active shortcut, each press, Accessibility changes, the media-key tap, recording, and setup |
| `login` | launch at login: each register or unregister with the resulting status, and status changes |
