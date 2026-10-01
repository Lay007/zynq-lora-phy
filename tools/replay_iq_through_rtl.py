#!/usr/bin/env python3
"""Replay recorded IQ through the real receiver RTL, sweeping arrival phase.

The programmable logic's decisions depend on where a packet lands against the
receiver's free-running symbol grid, and that phase cannot be recovered from a
recording. So each recording is cut into a window whose start is shifted by K
samples (K = 0..1023 covers one symbol) and every window is run through
fpga/tb/tb_replay_detect.sv under vvp. This is how the ~7% of packets the
detector never saw were found to be a phase-dependent blind band
(docs/clg400-joint-grid-experiment.md, M7).

Build the simulator once (see the header of the testbench), then, from the
repository root (the receiver loads fpga/rom/lora_sf7_l8_reference_q10.mem by
a relative path):

    python tools/replay_iq_through_rtl.py --vvp-file replay_tb \
        --phases 0:1024:32 --workers 7 --out sweep.json \
        experiments/runs/<run>/rx1-iq-<stamp>.bin

A window is about 27k samples and takes about a minute per phase; the joint
search adds a minute or two because the testbench waits for it to finish.

Every result carries the detection(s) [bin, chips_to_boundary, sample],
packet_start_count, the joint controller's outcome line and the raw symbol
decisions, so the pattern around the preamble/sync boundary can be read
directly. The printed summary is one line per recording, '#' where the packet
was detected and '.' where it was not, one character per phase.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.analyze_clg400_iq_trace import burst_bounds, load_iq  # noqa: E402

LEAD_SAMPLES = 2048  # default; --lead overrides (silence before the packet matters)
TAIL_SAMPLES = 24 * 1024


def write_window(iq: np.ndarray, start: int, count: int, path: Path) -> None:
    segment = iq[start : start + count]
    i = np.round(segment.real).astype(np.int64) & 0xFFFF
    q = np.round(segment.imag).astype(np.int64) & 0xFFFF
    path.write_text(
        "\n".join(f"{(a << 16) | b:08x}" for a, b in zip(i, q)) + "\n"
    )


def parse_output(text: str) -> dict[str, object]:
    return {
        "det": [
            [int(v) for v in m]
            for m in re.findall(r"^DET (\d+) (\d+) n=(\d+)", text, re.M)
        ],
        "straddle": [
            int(v) for v in re.findall(r"^DET \d+ \d+ n=\d+ straddle=(\d)", text, re.M)
        ],
        "split": [
            int(v) for v in re.findall(r"^DET \d+ \d+ n=\d+ straddle=\d split=(\d)", text, re.M)
        ],
        "meta": [
            [int(c), int(f)] for c, f in re.findall(r"^META (\d+) (-?\d+)", text, re.M)
        ],
        "psc": [int(v) for v in re.findall(r"^PSC (\d+)", text, re.M)],
        "joint": re.findall(r"^JNT (.*)$", text, re.M),
        "symbols": [int(v) for v in re.findall(r"^SYM (\d+) \d+", text, re.M)],
    }


def run_one(job: tuple[Path, int, str, Path, bool, int]) -> dict[str, object]:
    iq_path, shift, vvp_file, workdir, wait_joint, lead = job
    iq = load_iq(iq_path)
    burst_start, _ = burst_bounds(iq)
    start = burst_start - lead - shift
    count = lead + shift + TAIL_SAMPLES
    if start < 0:
        raise ValueError(f"{iq_path.name}: the burst is too close to the start")
    hex_path = workdir / f"{iq_path.stem}_{shift:04d}.hex"
    write_window(iq, start, count, hex_path)
    try:
        completed = subprocess.run(
            [
                "vvp",
                vvp_file,
                "+iq=" + hex_path.as_posix(),
                f"+n={count}",
                f"+wait_joint={int(wait_joint)}",
            ],
            capture_output=True,
            text=True,
            timeout=3600,
            check=False,
        )
    finally:
        hex_path.unlink(missing_ok=True)
    result = parse_output(completed.stdout)
    result.update(file=iq_path.name, shift=shift, burst_start=burst_start)
    return result


def parse_phases(spec: str) -> list[int]:
    start, stop, step = (int(v) for v in spec.split(":"))
    return list(range(start, stop, step))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("iq", nargs="+", type=Path, help="raw int16 I/Q recordings")
    parser.add_argument("--vvp-file", required=True, help="compiled tb_replay_detect")
    parser.add_argument("--phases", default="0:1024:32", help="start:stop:step shifts")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument(
        "--no-joint",
        action="store_true",
        help="do not wait for the joint search (detection only, much faster)",
    )
    parser.add_argument(
        "--lead",
        type=int,
        default=LEAD_SAMPLES,
        help="samples of the recording before the burst to feed first; the "
        "detector sees these as silence, and a long stretch of it is what "
        "exposes rules that a quiet input satisfies for free",
    )
    parser.add_argument("--out", type=Path, default=Path("replay_sweep.json"))
    args = parser.parse_args()

    phases = parse_phases(args.phases)
    with tempfile.TemporaryDirectory() as tmp:
        jobs = [
            (path, shift, args.vvp_file, Path(tmp), not args.no_joint, args.lead)
            for path in args.iq
            for shift in phases
        ]
        with ThreadPoolExecutor(args.workers) as pool:
            results = list(pool.map(run_one, jobs))
    args.out.write_text(json.dumps(results))
    for path in args.iq:
        rows = [r for r in results if r["file"] == path.name]
        print(path.name, "".join("#" if r["det"] else "." for r in rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
