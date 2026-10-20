"""Start the helper bundled in a built StopPlease.app the way the app does, and
send one `list`. Used by CI on each macOS runner image.

Passes when the helper reports `ready` (Perl loaded our library, MediaRemote and
every symbol resolved, commands 0/1 are still Play/Pause) and answers the `list`
with ok. A `list` is read-only. CI runners have no players, so an empty list is
expected there; it cannot show whether other apps' sources would be visible.

Usage: python3 -I tests/helper_smoke.py path/to/StopPlease.app
"""
import json
import pathlib
import subprocess
import sys

# Absolute: dyld refuses relative library paths inside the hardened Perl.
app = pathlib.Path(sys.argv[1]).resolve()
# Closing stdin after the request makes the helper exit once it has replied.
helper = subprocess.run(
    ["/usr/bin/perl", str(app / "Contents/Resources/perl_helper.pl"),
     str(app / "Contents/Frameworks/libNowPlayingPerlHelper.dylib")],
    input=json.dumps({"id": 1, "op": "list"}) + "\n",
    capture_output=True, text=True, encoding="utf-8", timeout=30,
    # PATH only, as HelperClient: no inherited PERL5OPT or PERL5LIB.
    env={"PATH": "/usr/bin:/bin"},
)
if helper.stderr:
    print(f"Helper stderr:\n{helper.stderr}", end="")
lines = [json.loads(line) for line in helper.stdout.splitlines()]

startup = lines[0] if lines else {}
if startup.get("event") != "ready":
    sys.exit(f"Helper did not start: {startup}")
print(f"Helper ready on {startup['operatingSystem']}")

reply = lines[1] if len(lines) > 1 else {}
if not reply.get("ok"):
    sys.exit(f"list failed: {reply}")
print(f"list ok, {len(reply['sources'])} sources: {json.dumps(reply)}")

if helper.returncode != 0:
    sys.exit(f"Helper exited with status {helper.returncode}")
