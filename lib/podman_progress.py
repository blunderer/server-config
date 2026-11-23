#!/usr/bin/env python3
"""Compact BuildKit-style single- and multi-row progress renderer for Podman."""
import argparse
import json
import os
import re
import shutil
import sys
import time

SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
STEP_RE = re.compile(r"^(?:\[(\d+)/(\d+)\]\s+)?STEP\s+(\d+)/(\d+):\s*(.+)$")
BLOB_RE = re.compile(r"^Copying\s+(blob|config)\s+([0-9a-f]+)(.*)$")
UNIT_RE = re.compile(r"Loading source unit file\s+(.+)$")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text).replace("\r", "").strip()


def pid_alive(pid: int) -> bool:
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as fh:
            data = fh.read()
        state = data.rsplit(")", 1)[1].split()[0]
        return state not in ("Z", "X")
    except FileNotFoundError:
        return False
    except OSError:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True


def fmt_elapsed(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.1f}s"
    mins, secs = divmod(int(seconds), 60)
    return f"{mins}m{secs:02d}s"


def truncate(text: str, width: int) -> str:
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    if width <= 3:
        return text[:width]
    return text[: width - 1] + "…"


class ProgressState:
    def __init__(self, label: str, is_tty: bool, emit_steps: bool = True) -> None:
        self.label = label
        self.is_tty = is_tty
        self.emit_steps = emit_steps
        self.step = 0
        self.total = 0
        self.stage = 0
        self.stages = 0
        self.units = 0
        self.detail = "starting…"
        self.blobs = 0
        self.cached = 0
        self.last_logged_step = None

    def feed(self, raw_line: str) -> None:
        line = strip_ansi(raw_line)
        if not line:
            return
        m = STEP_RE.match(line)
        if m:
            if m.group(1) and m.group(2):
                self.stage, self.stages = int(m.group(1)), int(m.group(2))
            self.step, self.total = int(m.group(3)), int(m.group(4))
            instr = " ".join(m.group(5).split())
            prefix = f"[{self.stage}/{self.stages}] " if self.stages > 1 else ""
            self.detail = f"{prefix}{instr}"
            if not self.is_tty and self.emit_steps:
                key = (self.stage, self.step, self.total, instr)
                if key != self.last_logged_step:
                    self.last_logged_step = key
                    print(f"    {prefix}[{self.step}/{self.total}] {truncate(instr, 72)}", flush=True)
            return
        m = UNIT_RE.search(line)
        if m:
            self.units += 1
            self.detail = os.path.basename(m.group(1).strip())
            return
        if line.startswith("--> Using cache"):
            self.cached += 1
            if "(cached)" not in self.detail:
                self.detail = f"{self.detail} (cached)"
            return
        m = BLOB_RE.match(line)
        if m:
            kind, digest, rest = m.group(1), m.group(2)[:12], m.group(3).strip()
            if kind == "blob":
                self.blobs += 1
            extra = f" {rest}" if rest else ""
            self.detail = f"copying {kind} {digest}{extra}"
            return
        if line.startswith(("Trying to pull", "Getting image", "Writing manifest", "COMMIT ")):
            self.detail = line

    def render_bar(self, frame: int, elapsed: float, cols: int | None = None) -> str:
        if cols is None:
            cols = shutil.get_terminal_size((100, 24)).columns
        spin = SPINNER[frame % len(SPINNER)]
        el = fmt_elapsed(elapsed)
        if self.total > 0:
            bar_w = 14
            filled = min(bar_w, max(0, int(round(bar_w * self.step / self.total))))
            bar = "█" * filled + "░" * (bar_w - filled)
            prefix = f"  {spin} [{bar}] {self.step}/{self.total} {self.label}: "
        else:
            prefix = f"  {spin} {self.label}: "
        suffix = f" ({el})"
        avail = cols - len(prefix) - len(suffix) - 1
        if avail < 10:
            return truncate(f"{prefix.rstrip()}{suffix}", cols - 1)
        return f"{prefix}{truncate(self.detail, avail)}{suffix}"

    def render_done(self, rc: int, elapsed: float, use_color: bool) -> str:
        c_grn = "\x1b[32m" if use_color else ""
        c_red = "\x1b[31m" if use_color else ""
        c_off = "\x1b[0m" if use_color else ""
        el = fmt_elapsed(elapsed)
        if rc == 0:
            if self.total > 0:
                extra = f"{self.total}/{self.total} steps, {el}"
            elif self.units > 0:
                extra = f"{self.units} units, {el}"
            else:
                extra = el
            return f"{c_grn} ok{c_off} {self.label} ({extra})"
        return f"{c_red}FAIL{c_off} {self.label} ({el}, exit {rc})"


def read_tail(log_path: str, limit: int = 80) -> tuple[list[str], int]:
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
            lines = [ln.rstrip("\n") for ln in fh]
        return lines[-limit:], len(lines)
    except FileNotFoundError:
        return [], 0


def run_watch(pid: int, log_path: str, label: str, start_ts: float) -> int:
    is_tty = sys.stdout.isatty()
    state = ProgressState(label, is_tty)
    if not is_tty:
        print(f"  .. {label}", flush=True)
    pos = 0
    frame = 0
    while True:
        try:
            with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
                fh.seek(pos)
                chunk = fh.read()
                pos = fh.tell()
        except FileNotFoundError:
            chunk = ""
        if chunk:
            for line in chunk.splitlines():
                state.feed(line)
        if is_tty:
            elapsed = max(0.0, time.time() - start_ts)
            sys.stdout.write("\r\x1b[2K" + state.render_bar(frame, elapsed))
            sys.stdout.flush()
            frame += 1
        if not pid_alive(pid):
            break
        time.sleep(0.1)
    return 0


def run_finish(rc: int, log_path: str, label: str, start_ts: float) -> int:
    is_tty = sys.stdout.isatty()
    elapsed = max(0.0, time.time() - start_ts)
    state = ProgressState(label, is_tty=True)
    tail, total_lines = read_tail(log_path, limit=100000)
    for raw in tail:
        state.feed(raw)
    if is_tty:
        sys.stdout.write("\r\x1b[2K")
    if rc == 0:
        print(state.render_done(0, elapsed, is_tty), flush=True)
        return 0
    print(state.render_done(rc, elapsed, is_tty), file=sys.stderr, flush=True)
    shown = tail[-80:]
    if total_lines > 80:
        print(f"--- showing last 80 of {total_lines} lines (re-run with -v for full output) ---", file=sys.stderr)
    for line in shown:
        print(line, file=sys.stderr)
    return rc


def _read_float(path: str) -> float | None:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return float(fh.read().strip())
    except (FileNotFoundError, ValueError, OSError):
        return None


def _read_int(path: str) -> int | None:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            val = fh.read().strip()
            return int(val) if val else None
    except (FileNotFoundError, ValueError, OSError):
        return None


def run_multi(job_dir: str) -> int:
    with open(os.path.join(job_dir, "jobs.json"), "r", encoding="utf-8") as fh:
        specs = json.load(fh)
    is_tty = sys.stdout.isatty()
    c_dim = "\x1b[2m" if is_tty else ""
    c_off = "\x1b[0m" if is_tty else ""
    jobs = []
    for spec in specs:
        jid = spec["id"]
        jobs.append(
            {
                "id": jid,
                "label": spec["label"],
                "log": os.path.join(job_dir, f"{jid}.log"),
                "start_file": os.path.join(job_dir, f"{jid}.start"),
                "rc_file": os.path.join(job_dir, f"{jid}.rc"),
                "state": ProgressState(spec["label"], is_tty, emit_steps=False),
                "pos": 0,
                "start_ts": None,
                "end_ts": None,
                "rc": None,
                "printed": False,
            }
        )

    frame = 0
    drawn = False
    n = len(jobs)
    while True:
        all_done = True
        now = time.time()
        for j in jobs:
            if j["start_ts"] is None:
                j["start_ts"] = _read_float(j["start_file"])
            # Always drain new log output
            try:
                with open(j["log"], "r", encoding="utf-8", errors="replace") as fh:
                    fh.seek(j["pos"])
                    chunk = fh.read()
                    j["pos"] = fh.tell()
            except FileNotFoundError:
                chunk = ""
            if chunk:
                for line in chunk.splitlines():
                    j["state"].feed(line)
            if j["rc"] is None:
                rc = _read_int(j["rc_file"])
                if rc is not None:
                    j["rc"] = rc
                    try:
                        j["end_ts"] = os.path.getmtime(j["rc_file"])
                    except OSError:
                        j["end_ts"] = now
                    if not is_tty and not j["printed"]:
                        el = max(0.0, j["end_ts"] - (j["start_ts"] or j["end_ts"]))
                        print(j["state"].render_done(rc, el, False), flush=True)
                        j["printed"] = True
                else:
                    all_done = False

        if is_tty and n > 0:
            cols = shutil.get_terminal_size((100, 24)).columns
            buf = []
            if drawn:
                buf.append(f"\x1b[{n}A")
            for j in jobs:
                if j["rc"] is not None:
                    el = max(0.0, (j["end_ts"] or now) - (j["start_ts"] or now))
                    row = j["state"].render_done(j["rc"], el, True)
                elif j["start_ts"] is not None:
                    el = max(0.0, now - j["start_ts"])
                    row = j["state"].render_bar(frame, el, cols)
                else:
                    row = f"  {c_dim}· {j['label']} (queued){c_off}"
                buf.append(f"\r\x1b[2K{row}\n")
            sys.stdout.write("".join(buf))
            sys.stdout.flush()
            drawn = True
            frame += 1

        if all_done:
            break
        time.sleep(0.1)

    failed = [j for j in jobs if j["rc"] != 0]
    for j in failed:
        tail, total_lines = read_tail(j["log"], limit=80)
        print(f"\n--- {j['label']} failed (exit {j['rc']}) ---", file=sys.stderr)
        if total_lines > 80:
            print(f"--- showing last 80 of {total_lines} lines (re-run with -v for full output) ---", file=sys.stderr)
        for line in tail:
            print(line, file=sys.stderr)
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--multi", help="Directory containing jobs.json for multi-row rendering")
    parser.add_argument("--label")
    parser.add_argument("--log")
    parser.add_argument("--start", type=float, default=0.0)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--finish", type=int)
    args = parser.parse_args()
    if args.multi:
        return run_multi(args.multi)
    if not args.label or not args.log:
        return 2
    start_ts = args.start if args.start > 0 else time.time()
    if args.finish is not None:
        return run_finish(args.finish, args.log, args.label, start_ts)
    if args.pid is not None:
        return run_watch(args.pid, args.log, args.label, start_ts)
    return 2


if __name__ == "__main__":
    sys.exit(main())
