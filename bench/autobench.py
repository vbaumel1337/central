#!/usr/bin/env python3
"""Automated benchmark for Central's hitbox history.

    python bench/autobench.py                      # Current and Ref, default sizes
    python bench/autobench.py --impl Current,Union # pick implementations (see bench/Implementations.luau)
    python bench/autobench.py --label "after hoisting params reads"
    python bench/autobench.py --repeats 3          # best of 3 launches each; use for small changes
    python bench/autobench.py --baseline bench/results/<file>.json

What it does, per implementation, each in a FRESH Studio process:
  1. builds a place with Rojo from the working tree (lib/, bench/, tests/, Packages/)
  2. opens it in Roblox Studio, where a temporary plugin runs bench/auto/AutoRun.luau
  3. reads the results back out of Studio's log file and closes that Studio window

The Studio window is kept minimized while it runs (--show-studio to see it).

Then it writes bench/results/<time>_<branch>_<commit>.json and prints a summary, with the change
against the previous result (or --baseline).

One implementation per Studio process is deliberate. Measured back to back in one session, whichever
implementation ran last at 400 hitboxes reported per-query costs several times too high.

The first launch also runs the differential harness (Current vs Ref) as a correctness gate. A
benchmark of an implementation that returns wrong answers is worthless, so mismatches fail the run.

Expect noise. Two identical runs differ by up to ~15% on some cells (and more at 10 hitboxes,
where UpdateFrame is only ~10 us). --repeats N launches each implementation N times and keeps the
lowest figure per cell, which is the standard way to strip interference from a timing.

Everything runs in Studio's edit mode, in the plugin's thread. Numbers are comparable with each
other and across runs of this script, NOT with figures measured in a Play session.

Requirements: Windows, Roblox Studio installed and signed in, `rojo` on PATH, and `wally install`
already run in this repo (the place needs Packages/).
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUTO = os.path.join(ROOT, "bench", "auto")
WORK = os.path.join(AUTO, ".work")
RESULTS = os.path.join(ROOT, "bench", "results")

PLUGIN_NAME = "CentralAutoBench.rbxm"
MARKER = "CENTRAL_BENCH|"

# (key in a result row, column heading)
METRICS = [
    ("updateFrameUs", "UpdateFrame"),
    ("rayHitUs", "ray hit"),
    ("rayMissUs", "ray miss"),
    ("shapeHitUs", "shape hit"),
    ("shapeMissUs", "shape miss"),
]


class BenchError(Exception):
    pass


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kwargs)


def git(*args: str) -> str:
    result = run(["git", *args])
    return result.stdout.strip() if result.returncode == 0 else ""


def local_app_data() -> str:
    path = os.environ.get("LOCALAPPDATA")
    if not path:
        raise BenchError("LOCALAPPDATA is not set; this script only runs on Windows")
    return path


def find_studio() -> str:
    candidates = glob.glob(os.path.join(local_app_data(), "Roblox", "Versions", "*", "RobloxStudioBeta.exe"))
    if not candidates:
        raise BenchError("Roblox Studio not found under %LOCALAPPDATA%\\Roblox\\Versions")
    return max(candidates, key=os.path.getmtime)


SW_SHOWMINNOACTIVE = 7


def minimized_startupinfo() -> subprocess.STARTUPINFO | None:
    """Asks Windows to open the new process's first window minimized and without taking focus.

    Studio does not always honour this (its main window is created after a splash screen), which is
    why keep_minimized() also runs while the benchmark is being waited on.
    """
    if os.name != "nt":
        return None
    info = subprocess.STARTUPINFO()
    info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    info.wShowWindow = SW_SHOWMINNOACTIVE
    return info


def keep_minimized(pid: int) -> None:
    """Minimizes every visible top-level window the process owns, without activating it.

    Studio opens maximised, over whatever the user is doing. The benchmark does not need to be
    seen, only to run, so it is sent to the taskbar as soon as it has a window.
    """
    if os.name != "nt":
        return

    user32 = ctypes.windll.user32
    enum_proc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def visit(hwnd, _) -> bool:
        owner = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd) and not user32.IsIconic(hwnd):
            user32.ShowWindow(hwnd, SW_SHOWMINNOACTIVE)
        return True

    user32.EnumWindows(enum_proc(visit), 0)


def rojo_build(project: str, output: str) -> None:
    if not shutil.which("rojo"):
        raise BenchError("`rojo` is not on PATH")
    result = run(["rojo", "build", project, "-o", output])
    if result.returncode != 0:
        raise BenchError(f"rojo build failed for {os.path.relpath(project, ROOT)}:\n{result.stderr.strip()}")


class LogTail:
    """Follows every Studio log file written since it was created, yielding marker lines."""

    def __init__(self, token: str):
        self.directory = os.path.join(local_app_data(), "Roblox", "logs")
        self.prefix = f"{MARKER}{token}|"
        self.started = time.time()
        self.offsets: dict[str, int] = {}

    def poll(self) -> list[tuple[str, dict]]:
        messages = []
        for path in glob.glob(os.path.join(self.directory, "*Studio*.log")):
            try:
                if os.path.getmtime(path) < self.started - 5:
                    continue
                with open(path, "rb") as handle:
                    handle.seek(self.offsets.get(path, 0))
                    chunk = handle.read()
            except OSError:
                continue

            # only consume whole lines; a partial one is picked up on the next poll
            end = chunk.rfind(b"\n")
            if end < 0:
                continue
            self.offsets[path] = self.offsets.get(path, 0) + end + 1

            for line in chunk[: end + 1].decode("utf-8", errors="replace").splitlines():
                at = line.find(self.prefix)
                if at < 0:
                    continue
                kind, _, payload = line[at + len(self.prefix):].partition("|")
                try:
                    messages.append((kind, json.loads(payload)))
                except json.JSONDecodeError:
                    messages.append(("error", {"message": f"unreadable result line: {line[at:at + 200]}"}))
        return messages


def run_in_studio(studio: str, config: dict, timeout: float, visible: bool = False) -> list[tuple[str, dict]]:
    """Builds a place around `config`, runs it in a fresh Studio, returns the messages it emitted."""
    token = config["token"]
    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "RunConfig.json"), "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)

    # a fresh file name per launch, so Studio never offers to recover an earlier run's copy
    place = os.path.join(WORK, f"autobench-{token}.rbxl")
    rojo_build(os.path.join(AUTO, "place.project.json"), place)

    tail = LogTail(token)
    process = subprocess.Popen([studio, place], startupinfo=None if visible else minimized_startupinfo())
    messages: list[tuple[str, dict]] = []
    deadline = time.time() + timeout
    try:
        while True:
            for message in tail.poll():
                messages.append(message)
                kind, payload = message
                if kind == "row":
                    print(f"    {payload['implementation']} @ {payload['hitboxes']} hitboxes", flush=True)
                if kind == "done":
                    return messages
            if process.poll() is not None:
                raise BenchError("Studio closed before the benchmark finished")
            if not visible:
                keep_minimized(process.pid)
            if time.time() > deadline:
                raise BenchError(
                    f"no result from Studio after {timeout:.0f}s. Is it waiting on a login or update "
                    "dialog? Did the CentralAutoBench plugin load (check Studio's Plugins tab)?"
                )
            time.sleep(0.5)
    finally:
        # /T takes any child processes with it; the place has unsaved benchmark parts in it, so
        # there is nothing worth closing gracefully for
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            pass
        for leftover in (place, place + ".lock"):
            try:
                os.remove(leftover)
            except OSError:
                pass


def fmt(value) -> str:
    return f"{value:.2f}" if isinstance(value, (int, float)) else "-"


def delta(new, old) -> str:
    if not isinstance(new, (int, float)) or not isinstance(old, (int, float)) or old == 0:
        return ""
    return f" ({(new - old) / old * 100:+.0f}%)"


def summarize(result: dict, baseline: dict | None) -> str:
    lines = []
    meta = result["meta"]
    state = " (uncommitted changes)" if meta["dirty"] else ""
    lines.append(f"Central benchmark: {meta['branch']} @ {meta['commit']}{state}" + (f" - {meta['label']}" if meta["label"] else ""))

    differential = result.get("differential")
    if differential:
        verdict = "PASS" if differential["mismatches"] == 0 else "FAIL"
        lines.append(
            f"Differential (Current vs Ref): {verdict}, {differential['mismatches']} mismatches "
            f"in {differential['queries']} queries over {differential['frames']} frames"
        )
        for text in differential.get("first", []):
            lines.append(f"    {text}")

    owned = result.get("owned")
    if owned:
        verdict = "PASS" if not owned["failures"] else "FAIL"
        lines.append(f"Owned hitboxes: {verdict}, {len(owned['failures'])} failures in {owned['checks']} checks")
        for text in owned["failures"]:
            lines.append(f"    {text}")

    group = result.get("group")
    if group:
        verdict = "PASS" if not group["failures"] else "FAIL"
        lines.append(f"Group hitboxes: {verdict}, {len(group['failures'])} failures in {group['checks']} checks")
        for text in group["failures"]:
            lines.append(f"    {text}")

    old_rows = {}
    if baseline:
        old_meta = baseline["meta"]
        lines.append(f"Change is against: {old_meta['branch']} @ {old_meta['commit']}, {old_meta['timestamp']}" + (f" - {old_meta['label']}" if old_meta.get("label") else ""))
        old_rows = {(row["implementation"], row["hitboxes"]): row for row in baseline["rows"]}

    lines.append("")
    lines.append("All figures in microseconds: UpdateFrame per frame, the rest per query.")
    lines.append("")
    lines.append("| implementation | hitboxes | " + " | ".join(heading for _, heading in METRICS) + " |")
    lines.append("|---|---|" + "---|" * len(METRICS))
    for row in result["rows"]:
        old = old_rows.get((row["implementation"], row["hitboxes"]), {})
        cells = [fmt(row.get(key)) + delta(row.get(key), old.get(key)) for key, _ in METRICS]
        lines.append(f"| {row['implementation']} | {row['hitboxes']} | " + " | ".join(cells) + " |")

    notes = [note for row in result["rows"] for note in row.get("notes") or []]
    if notes:
        lines.append("")
        lines.append("Notes from the harness (a case that did not behave as labelled):")
        lines.extend(f"    {note}" for note in notes)

    return "\n".join(lines)


def latest_result(exclude: str) -> dict | None:
    files = sorted(glob.glob(os.path.join(RESULTS, "*.json")))
    files = [path for path in files if os.path.abspath(path) != os.path.abspath(exclude)]
    if not files:
        return None
    with open(files[-1], encoding="utf-8") as handle:
        return json.load(handle)


def int_list(text: str) -> list[int]:
    return [int(part) for part in text.split(",") if part.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description="Automated benchmark for Central's hitbox history.")
    parser.add_argument("--impl", default="Current,Ref", help="comma-separated implementations from bench/Implementations.luau (default: Current,Ref)")
    parser.add_argument("--hitboxes", default="10,100,400", type=int_list, help="hitbox counts (default: 10,100,400)")
    parser.add_argument("--queries", default=500, type=int, help="queries per frame the per-query cost is measured at (default: 500)")
    parser.add_argument("--moving", default=1.0, type=float, help="share of hitboxes that move each frame, 0..1 (default: 1, the worst case; the rest stay put). Results at different values are not comparable.")
    parser.add_argument("--group-size", default=0, type=int, help="register every N consecutive grid parts as one group (a Model), 0 = each part on its own (default). Implementations that predate groups, such as Ref, ignore it, so they stay a control. Results at different values are not comparable.")
    parser.add_argument("--group-layout", default="grid", choices=["grid", "cluster"], help="with --group-size: 'grid' groups N consecutive grid parts, each still moving on its own (default); 'cluster' puts a group's parts together and moves them as one, like the parts of a character. Results at different values are not comparable.")
    parser.add_argument("--params", action="store_true", help="pass RaycastParams (an exclude list and a collision group) to every query, to measure filtering. Results with and without are not comparable.")
    parser.add_argument("--label", default="", help="free text stored with the result, e.g. what this iteration changed")
    parser.add_argument("--baseline", help="result file to compare against (default: the most recent one in bench/results)")
    parser.add_argument("--no-differential", action="store_true", help="skip the Current-vs-Ref correctness gate")
    parser.add_argument("--differential-frames", default=1500, type=int, help="frames the correctness gate runs (default: 1500)")
    parser.add_argument("--repeats", default=1, type=int, help="launches per implementation; the lowest figure per cell is kept (default: 1)")
    parser.add_argument("--no-isolate", action="store_true", help="run every implementation in one Studio process (faster, less trustworthy)")
    parser.add_argument("--timeout", default=300, type=float, help="seconds to wait for each Studio process (default: 300)")
    parser.add_argument("--no-save", action="store_true", help="print the summary without writing a result file")
    parser.add_argument("--show-studio", action="store_true", help="leave the Studio window the benchmark opens where it appears (default: keep it minimized)")
    args = parser.parse_args()

    implementations = [name.strip() for name in args.impl.split(",") if name.strip()]
    if not implementations:
        parser.error("--impl needs at least one implementation")

    if not os.path.isdir(os.path.join(ROOT, "Packages")):
        raise BenchError("Packages/ is missing; run `wally install` in the repo first")

    studio = find_studio()
    plugin_path = os.path.join(local_app_data(), "Roblox", "Plugins", PLUGIN_NAME)
    os.makedirs(os.path.dirname(plugin_path), exist_ok=True)

    base_config = {
        "hitboxCounts": args.hitboxes,
        "queryCount": args.queries,
        "movingFraction": args.moving,
        "groupSize": args.group_size,
        "groupLayout": args.group_layout,
        "withParams": args.params,
        "differentialFrames": args.differential_frames,
        # see bench/RunBenchmarkSheets.luau's consumer notes for why these values
        "warmupFrames": 171,
        "framesPerBatch": 20,
        "numBatches": 7,
        "stepBudgetUs": 16667,
        "timeoutMultiple": 50,
    }

    groups = [implementations] if args.no_isolate else [[name] for name in implementations]
    # repeats are interleaved (A B C, A B C) rather than batched (A A, B B), so a slow spell on the
    # machine lands on every implementation instead of on one
    groups = groups * max(1, args.repeats)
    samples: dict[tuple[str, int], list[dict]] = {}
    differential = None
    owned = None
    group_test = None
    errors: list[str] = []

    rojo_build(os.path.join(AUTO, "plugin.project.json"), plugin_path)
    try:
        for index, group in enumerate(groups):
            wants_differential = index == 0 and not args.no_differential
            print(f"[{index + 1}/{len(groups)}] {', '.join(group)}" + (" (+ differential gate)" if wants_differential else ""), flush=True)
            config = dict(base_config, token=uuid.uuid4().hex[:12], implementations=group, differential=wants_differential)
            for kind, payload in run_in_studio(studio, config, args.timeout, args.show_studio):
                if kind == "row":
                    samples.setdefault((payload["implementation"], payload["hitboxes"]), []).append(payload)
                elif kind == "differential":
                    differential = payload
                elif kind == "owned":
                    owned = payload
                elif kind == "group":
                    group_test = payload
                elif kind == "error":
                    errors.append(payload.get("message", "unknown error"))
    finally:
        try:
            os.remove(plugin_path)
        except OSError:
            pass

    # one row per (implementation, hitbox count): the lowest figure seen for each metric
    rows: list[dict] = []
    for (implementation, hitboxes), seen in samples.items():
        row: dict = {"implementation": implementation, "hitboxes": hitboxes, "samples": len(seen)}
        for key, _ in METRICS:
            values = [sample[key] for sample in seen if isinstance(sample.get(key), (int, float))]
            if values:
                row[key] = min(values)
        row["notes"] = sorted({note for sample in seen for note in sample.get("notes") or []})
        rows.append(row)

    now = datetime.datetime.now()
    commit = git("rev-parse", "--short", "HEAD") or "unknown"
    branch = git("rev-parse", "--abbrev-ref", "HEAD") or "unknown"
    dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
    result = {
        "meta": {
            "timestamp": now.isoformat(timespec="seconds"),
            "branch": branch,
            "commit": commit,
            "dirty": dirty,
            "label": args.label,
            "studio": os.path.basename(os.path.dirname(studio)),
            "isolated": not args.no_isolate,
            "repeats": max(1, args.repeats),
            "config": base_config,
        },
        "differential": differential,
        "owned": owned,
        "group": group_test,
        "rows": rows,
        "errors": errors,
    }

    name = f"{now:%Y%m%d-%H%M%S}_{branch.replace('/', '-')}_{commit}{'_dirty' if dirty else ''}.json"
    path = os.path.join(RESULTS, name)

    if args.baseline:
        with open(args.baseline, encoding="utf-8") as handle:
            baseline = json.load(handle)
    else:
        baseline = latest_result(exclude=path)

    print()
    print(summarize(result, baseline))

    if not args.no_save and rows:
        os.makedirs(RESULTS, exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
        print(f"\nSaved {os.path.relpath(path, ROOT)}")

    for message in errors:
        print(f"ERROR in Studio: {message}", file=sys.stderr)
    if errors or not rows:
        return 1
    if owned and owned["failures"]:
        print("FAILED: the owned-hitbox test failed; do not trust these numbers.", file=sys.stderr)
        return 2
    if group_test and group_test["failures"]:
        print("FAILED: the group-hitbox test failed; do not trust these numbers.", file=sys.stderr)
        return 2
    if differential and differential["mismatches"] > 0:
        print("FAILED: the differential gate found mismatches; do not trust these numbers.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BenchError as error:
        print(f"autobench: {error}", file=sys.stderr)
        sys.exit(1)
