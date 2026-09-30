#!/usr/bin/env python3
"""Recompute a PL PER result from its stored symbol traces with the current decoder.

tools/per_measure.py keeps every raw trace (`sym`, `pbin`, `realigned`) in its
JSON, so a host-side decoder fix does not need a new bench run: this decodes
each record again, rebuilds the sequence list and recomputes PER per point.
Points measured by attempts (almost nothing received) keep their method.

    python tools/per_redecode.py experiments/per/sf7_cr2_pl_g57.json --out ...
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

from per_measure import per_from_sequences, seq_of  # noqa: E402
from zynq_lora_phy.lora_packet import decode_lora_symbol_trace  # noqa: E402


def redecode_point(point: dict, period: int) -> dict:
    seqs: list[int] = []
    crc_bad = 0
    for r in point["records"]:
        if not r.get("sym"):
            continue
        syms = [int(r["sym"][2 * k:2 * k + 2], 16) for k in range(len(r["sym"]) // 2)]
        pbin = 0 if r["realigned"] else r["pbin"]
        res = decode_lora_symbol_trace(syms, pbin).result
        s = seq_of(bytes(res.payload)) if res.crc_valid else None
        r["crc"], r["seq"] = bool(res.crc_valid), s
        if s is None:
            crc_bad += 1
        else:
            seqs.append(s)
    new = dict(point)
    new.update(per_from_sequences(seqs, 0, period))
    new["crc_fail"] = crc_bad
    # the same rule as per_measure.measure_pl
    attempts = point.get("attempts") or len(point["records"])
    if new["per"] is None or new["received_valid"] < 2:
        new["per"] = 1.0 - new["received_valid"] / attempts if attempts else None
        new["per_method"] = "per attempt"
    else:
        new["per_method"] = "sequence gaps"
    return new


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("result", type=Path)
    ap.add_argument("--out", type=Path, help="default: overwrite the input")
    args = ap.parse_args()
    d = json.loads(args.result.read_text())
    period = d["templates"]
    for i, p in enumerate(d["points"]):
        old = p["per"]
        d["points"][i] = redecode_point(p, period)
        print(f"SNR {p['snr_db']:+6.1f} dB  PER {old:.4f} -> {d['points'][i]['per']:.4f}", flush=True)
    d["redecoded"] = "tools/per_redecode.py with the current decoder"
    (args.out or args.result).write_text(json.dumps(d, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
