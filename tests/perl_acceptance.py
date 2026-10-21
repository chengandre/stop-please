"""Run the acceptance tests (Tests H, E, F, and optionally G; see DEVELOPMENT.md)
through one long-running Perl-hosted helper, against the three fixture apps.

Every request and reply is saved under Outputs/ACCEPTANCE_<timestamp>/ with a
summary. States are MediaRemote-reported; whether you heard each change, and
which app came to the front, is up to you. Test G quits YouTube Music, so it
runs only with --test-g.
"""
import argparse
import datetime
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIBRARY = ROOT / ".build" / "libNowPlayingPerlHelper.dylib"
# Fixtures for this test only; the helper itself has no app-specific code.
FIXTURES = {
    "Spotify": "com.spotify.client",
    "Zen": "app.zen-browser.zen",
    "YouTube Music": "com.github.th-ch.youtube-music",
}
EXPECTED_STATE = {"play": "Playing", "pause": "Paused"}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--test-g", action="store_true", help="also run Test G, which quits YouTube Music (SIGTERM)")
args = parser.parse_args()

out_dir = ROOT / "Outputs" / f"ACCEPTANCE_{datetime.datetime.now():%Y%m%d-%H%M%S}"
out_dir.mkdir(parents=True)
log_lines = []
step_number = 0


def log(line=""):
    print(line, flush=True)
    log_lines.append(line)


def request(label, **fields):
    """Send one request to the helper, save it with its reply, and return the reply.
    A route-level error ends the run."""
    global step_number
    step_number += 1
    message = {"id": step_number, **fields}
    helper.stdin.write(json.dumps(message) + "\n")
    helper.stdin.flush()
    line = helper.stdout.readline()
    if not line:
        sys.exit(f"{label}: helper exited with status {helper.wait()}")
    reply = json.loads(line)
    capture = {"request": message, "reply": reply}
    (out_dir / f"{step_number:02d}_{label}.json").write_text(json.dumps(capture, ensure_ascii=False, indent=2))
    if not reply["ok"]:
        sys.exit(f"{label} failed: {reply['error']}")
    return reply


def listing(label):
    return request(label, op="list")


def settled_listing(label):
    """List until two lists 50 ms apart agree on every state (at most 2 s), so a
    source that is still settling, such as a browser video restarting, is not
    blamed on the next command."""
    previous = listing(label)
    for _ in range(40):
        time.sleep(0.05)
        latest = listing(label)
        # The list order can change between lists, so compare by pid.
        if {s["pid"]: s["state"] for s in latest["sources"]} == {s["pid"]: s["state"] for s in previous["sources"]}:
            return latest
        previous = latest
    return latest


def by_pid(sources):
    return {source["pid"]: source for source in sources}


def identity(source):
    """What a paused group stores for one source; also the command target."""
    return {"pid": source["pid"], "clientBundle": source["clientBundle"]}


def fixture_targets(snapshot):
    targets = {}
    for name, bundle in FIXTURES.items():
        matches = [identity(s) for s in snapshot["sources"] if s["appBundle"] == bundle]
        if len(matches) != 1:
            sys.exit(f"Expected one Now Playing source for {name}; found {len(matches)}.")
        targets[name] = matches[0]
    return targets


def command(test, action, expected):
    """Send one command to the named fixtures, in order, and check every result.

    `expected` maps fixture name to the expected outcome, e.g. {"Spotify": "done"}.
    A list before and after the command checks that each `done` target reached
    the new state, that no other source changed, and that the first target's
    route is `direct` exactly when it was already current.
    """
    names = list(expected)
    label = f"{test}_{action}_{'+'.join(name.replace(' ', '') for name in names)}"
    before = settled_listing(f"{label}_before")
    started = time.monotonic()
    reply = request(label, op="command", action=action, targets=[targets[name] for name in names])
    milliseconds = 1000 * (time.monotonic() - started)
    after = by_pid(listing(f"{label}_after")["sources"])

    problems = []
    for name, result in zip(names, reply["results"]):
        state_after = after.get(result["pid"], {}).get("state")
        if result["outcome"] != expected[name]:
            problems.append(f"{name} {result['outcome']} (expected {expected[name]})")
        elif result["outcome"] == "done" and state_after != EXPECTED_STATE[action]:
            problems.append(f"{name} done but {state_after}")
    target_pids = {targets[name]["pid"] for name in names}
    others_changed = [
        source["appName"] for pid, source in by_pid(before["sources"]).items()
        if pid not in target_pids and pid in after and after[pid]["state"] != source["state"]
    ]
    if others_changed:
        problems.append(f"other sources changed: {', '.join(others_changed)}")
    first = reply["results"][0]
    if "route" in first:
        was_current = before["current"] is not None and before["current"]["pid"] == first["pid"]
        if first["route"] != ("direct" if was_current else "override"):
            problems.append(f"route {first['route']} although current was {before['current']}")

    routes = ", ".join(result.get("route", "-") for result in reply["results"])
    log(f"  {datetime.datetime.now():%H:%M:%S} {test:9} {action:5} {' + '.join(names):30}"
        f" -> {'; '.join(problems) or 'pass'}"
        f" [{routes}; {milliseconds:.0f} ms]")
    return not problems


def expect_states(label, expected):
    sources = by_pid(listing(label)["sources"])
    states = {name: sources.get(targets[name]["pid"], {}).get("state") for name in expected}
    ok = states == expected
    log(f"  {label}: {'pass' if ok else 'FAIL'} {states}")
    return ok


LIBRARY.parent.mkdir(exist_ok=True)
subprocess.run(
    ["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-framework", "AppKit",
     str(ROOT / "NowPlayingPerlHelper" / "perl_helper.m"), "-o", str(LIBRARY)],
    check=True,
)
log(f"Acceptance run {out_dir.name}")
# A minimal environment, as the app will use: no inherited PERL5OPT or PERL5LIB.
helper = subprocess.Popen(
    ["/usr/bin/perl", str(ROOT / "NowPlayingPerlHelper" / "perl_helper.pl"), str(LIBRARY)],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8", env={"PATH": "/usr/bin:/bin"},
)
startup = json.loads(helper.stdout.readline() or "{}")
if startup.get("event") != "ready":
    sys.exit(f"Helper did not start: {startup}")
log(f"Helper ready on {startup['operatingSystem']}")

start = listing("setup_list")
targets = fixture_targets(start)
log(f"Fixtures: {targets}; current: {start['current']}")
results = {}

log("Setup: start every fixture playing")
start_states = by_pid(start["sources"])
not_playing = {name: "done" for name, target in targets.items() if start_states[target["pid"]]["state"] != "Playing"}
if not_playing:
    command("setup", "play", not_playing)
playing = {name: "Playing" for name in targets}
expect_states("setup_check", playing)

log("Test H: three alternating pause/play cycles")
tally = {(name, action): 0 for name in targets for action in ("pause", "play")}
for cycle in range(1, 4):
    for name in targets:
        for action in ("pause", "play"):
            tally[(name, action)] += command(f"H{cycle}", action, {name: "done"})
for (name, action), count in tally.items():
    log(f"  {name} {action}: {count}/3 correct")
results["H"] = all(count == 3 for count in tally.values())

log("Test E: identity across relist, play/pause, and current-player changes")
relisted = [identity(source) for source in listing("E_relist")["sources"]]
same = {name: target in relisted for name, target in targets.items()}
log(f"  after relist and Test H: identity unchanged {same}")
reuse_ok = all([command("E", "pause", {"Spotify": "done"}), command("E", "play", {"Spotify": "done"})])
results["E"] = all(same.values()) and reuse_ok

log("Test F: pause all playing as one group, resume Spotify + Zen, then YouTube Music")
snapshot = by_pid(listing("F_capture")["sources"])
group = [name for name, target in targets.items() if snapshot[target["pid"]]["state"] == "Playing"]
log(f"  captured playing group: {group}")
f_ok = command("F", "pause", {name: "done" for name in group})
f_ok &= expect_states("F_all_paused", {name: "Paused" for name in targets})
f_ok &= command("F", "play", {"Spotify": "done", "Zen": "done"})
f_ok &= expect_states("F_two_resumed", {"Spotify": "Playing", "Zen": "Playing", "YouTube Music": "Paused"})
f_ok &= command("F", "play", {"YouTube Music": "done"})
f_ok &= expect_states("F_all_resumed", playing)
results["F"] = f_ok

if args.test_g:
    log("Test G: a paused source quits before its group resumes")
    g_ok = command("G", "pause", {"Spotify": "done", "YouTube Music": "done"})
    quitting = targets["YouTube Music"]["pid"]
    os.kill(quitting, signal.SIGTERM)
    for _ in range(20):
        try:
            os.kill(quitting, 0)
        except ProcessLookupError:
            break
        time.sleep(0.5)
    else:
        sys.exit("YouTube Music did not quit within 10 s")
    g_ok &= quitting not in by_pid(listing("G_after_quit")["sources"])
    g_ok &= command("G", "play", {"YouTube Music": "notFound", "Spotify": "done"})
    results["G"] = g_ok

log("Teardown: pause every playing fixture")
final_states = by_pid(listing("teardown_capture")["sources"])
still_playing = {
    name: "done" for name, target in targets.items()
    if final_states.get(target["pid"], {}).get("state") == "Playing"
}
if still_playing:
    command("teardown", "pause", still_playing)
final = listing("teardown_list")
log(f"  final current client: {final['current']}")
helper.stdin.close()
log(f"  helper exit status: {helper.wait(timeout=10)}")

log(f"Results: {results}")
(out_dir / "summary.txt").write_text("\n".join(log_lines) + "\n")
log(f"Saved {out_dir}")
