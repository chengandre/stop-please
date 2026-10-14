"""Run the original acceptance tests (HANDOVER.md Tests E, F, H) through the
Perl-hosted helper's override-send mode, against the three fixture apps.

Every helper capture is saved under Outputs/ACCEPTANCE_<timestamp>/ with a
summary. States are MediaRemote-reported; audible/foreground behavior still
needs the user's observation. Test G (quitting an app) is not automated.
"""
import datetime
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIBRARY = ROOT / ".build" / "libNowPlayingPerlHelper.dylib"
# Fixtures for this test only; the helper itself has no app-specific code.
FIXTURES = {
    "Spotify": "com.spotify.client",
    "Zen": "app.zen-browser.zen",
    "YouTube Music": "com.github.th-ch.youtube-music",
}
EXPECTED_STATE = {"play": "Playing", "pause": "Paused"}

out_dir = ROOT / "Outputs" / f"ACCEPTANCE_{datetime.datetime.now():%Y%m%d-%H%M%S}"
out_dir.mkdir(parents=True)
log_lines = []
step_number = 0


def log(line=""):
    print(line, flush=True)
    log_lines.append(line)


def helper(label, *arguments):
    """Run one helper invocation, save its JSON, and return it."""
    global step_number
    step_number += 1
    completed = subprocess.run(
        ["/usr/bin/perl", str(ROOT / "Scripts" / "perl_helper.pl"), str(LIBRARY), *arguments],
        capture_output=True, text=True, timeout=60,
    )
    (out_dir / f"{step_number:02d}_{label}.json").write_text(completed.stdout + completed.stderr)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {"error": f"exit {completed.returncode}: {completed.stdout}{completed.stderr}".strip()}


def by_pid(snapshot):
    return {source["pid"]: source for source in snapshot["sources"]}


def identity(source):
    """What a paused group would store for one source."""
    return (source["pid"], source["bundleIdentifier"], source["playerPath"])


def listing(label):
    result = helper(label, "list")
    if "error" in result:
        sys.exit(f"list failed: {result['error']}")
    return result


def fixture_pids(snapshot):
    pids = {}
    for name, bundle in FIXTURES.items():
        matches = [s["pid"] for s in snapshot["sources"] if s["applicationBundleIdentifier"] == bundle]
        if len(matches) != 1:
            sys.exit(f"Expected one Now Playing source for {name}; found {len(matches)}.")
        pids[name] = matches[0]
    return pids


def command(test, name, action, pid):
    """Send one override-send command and classify it (HANDOVER.md Test H classes)."""
    result = helper(f"{test}_{action}_{name.replace(' ', '')}", "override-send", action, str(pid))
    if "error" in result:
        outcome = f"command rejected: {result['error']}"
    else:
        before, after = by_pid(result["before"]), by_pid(result["after"])
        others_changed = [
            after[p]["applicationName"] for p in before
            if p != pid and p in after and before[p]["stateDescription"] != after[p]["stateDescription"]
        ]
        if f"-{pid}/" not in str(result["commandResult"]):
            outcome = f"wrong target: {result['commandResult']}"
        elif others_changed:
            outcome = f"wrong target affected: {', '.join(others_changed)}"
        elif action in EXPECTED_STATE and before[pid]["stateDescription"] == EXPECTED_STATE[action]:
            outcome = f"no transition: already {EXPECTED_STATE[action]}"
        elif action in EXPECTED_STATE and after.get(pid, {}).get("stateDescription") != EXPECTED_STATE[action]:
            outcome = f"accepted but no state change: {after.get(pid, {}).get('stateDescription')}"
        elif action == "next" and after[pid]["title"] == before[pid]["title"]:
            outcome = "accepted but title unchanged"
        else:
            outcome = "pass"
    log(f"  {test:9} {action:5} {name:13} -> {outcome}")
    return outcome == "pass"


def expect_states(label, pids, expected):
    sources = by_pid(listing(label))
    states = {name: sources[pid]["stateDescription"] for name, pid in pids.items()}
    ok = states == expected
    log(f"  {label}: {'pass' if ok else 'FAIL'} {states}")
    return ok


subprocess.run(
    ["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-framework", "AppKit",
     str(ROOT / "Scripts" / "perl_helper.m"), "-o", str(LIBRARY)],
    check=True,
)
log(f"Acceptance run {out_dir.name}")
start = listing("setup_list")
pids = fixture_pids(start)
baseline = {name: identity(by_pid(start)[pid]) for name, pid in pids.items()}
log(f"Fixtures: {pids}; current: {start['currentClientBundleIdentifier']}")
results = {}

log("Setup: start every fixture playing")
for name, pid in pids.items():
    if by_pid(start)[pid]["stateDescription"] != "Playing":
        command("setup", name, "play", pid)
playing = {name: "Playing" for name in pids}
expect_states("setup_check", pids, playing)

log("Test H: three alternating pause/play cycles")
tally = {(name, action): 0 for name in pids for action in ("pause", "play")}
for cycle in range(1, 4):
    for name, pid in pids.items():
        for action in ("pause", "play"):
            tally[(name, action)] += command(f"H{cycle}", name, action, pid)
for (name, action), count in tally.items():
    log(f"  {name} {action}: {count}/3 correct")
results["H"] = all(count == 3 for count in tally.values())

log("Test E: identity across relist, play/pause, current-player changes, and track change")
relisted = listing("E_relist")
same = {name: identity(by_pid(relisted)[pid]) == baseline[name] for name, pid in pids.items()}
log(f"  after relist and Test H: identity unchanged {same}")
track_ok = all([command("E", "Spotify", "next", pids["Spotify"]),
                command("E", "YouTube Music", "next", pids["YouTube Music"])])
after_track = listing("E_after_track")
same_after_track = {name: identity(by_pid(after_track)[pid]) == baseline[name] for name, pid in pids.items()}
log(f"  after track change: identity unchanged {same_after_track}")
reuse_ok = all([command("E", "Spotify", "pause", pids["Spotify"]),
                command("E", "Spotify", "play", pids["Spotify"])])
results["E"] = all(same.values()) and track_ok and all(same_after_track.values()) and reuse_ok

log("Test F: pause all playing, resume Spotify + Zen, then YouTube Music")
snapshot = listing("F_capture")
group = {name: pid for name, pid in pids.items() if by_pid(snapshot)[pid]["stateDescription"] == "Playing"}
log(f"  captured playing group: {sorted(group)}")
f_ok = all([command("F", name, "pause", pid) for name, pid in group.items()])
f_ok &= expect_states("F_all_paused", pids, {name: "Paused" for name in pids})
f_ok &= all([command("F", name, "play", pids[name]) for name in ("Spotify", "Zen")])
f_ok &= expect_states("F_two_resumed", pids, {"Spotify": "Playing", "Zen": "Playing", "YouTube Music": "Paused"})
f_ok &= command("F", "YouTube Music", "play", pids["YouTube Music"])
f_ok &= expect_states("F_all_resumed", pids, playing)
results["F"] = f_ok

log("Teardown: pause every fixture")
for name, pid in pids.items():
    command("teardown", name, "pause", pid)
final = listing("teardown_list")
log(f"  final current client: {final['currentClientBundleIdentifier']}")

log(f"Results: {results}")
(out_dir / "summary.txt").write_text("\n".join(log_lines) + "\n")
log(f"Saved {out_dir}")
