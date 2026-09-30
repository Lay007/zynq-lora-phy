#!/usr/bin/env python3
"""Where does a measured receiver lose against the ideal? Symbol-level diagnosis.

For every packet the PL detected (tools/per_measure.py records with `sym`), the
transmitted packet is known up to which template it was: the raw decisions are
compared with the encoded symbols of every template, at every plausible
header offset and bin adjustment, and the best match is taken. That gives,
per SNR point:

  * the PL's symbol error rate after detection, against the exact ideal SER
    at the same SNR (tools/lora_per_plots.ser_theory),
  * the shape of the errors: +-1 bin (timing or grid: a neighbour bin) versus
    anything else (noise picking a random bin),
  * how errors fall along the packet (early symbols vs late), which separates
    a timing drift from a noise-limited decision.

    python tools/per_diagnose.py experiments/per/sf7_cr1_pl_b.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

from lora_per_ideal import ldro_required, test_payload  # noqa: E402
from lora_per_plots import ser_theory  # noqa: E402
from zynq_lora_phy import encode_lora_packet  # noqa: E402
from zynq_lora_phy.lora_packet import quarter_symbol_bin_adjustments  # noqa: E402


def templates(sf: int, cr: int, count: int) -> np.ndarray:
    ldro = ldro_required(sf)
    return np.array([encode_lora_packet(test_payload(k), spreading_factor=sf, coding_rate=cr,
                                        low_data_rate_optimization=ldro).symbols for k in range(count)])


def best_match(raw: np.ndarray, pbin: int, tpl: np.ndarray, sf: int):
    m = 1 << sf
    n = tpl.shape[1]
    best = None
    for adj in quarter_symbol_bin_adjustments(sf):
        norm = (raw - pbin - adj) % m
        for off in range(0, 9):
            seg = norm[off: off + n]
            if len(seg) < n:
                continue
            errs = (tpl != seg[None, :]).sum(1)
            k = int(np.argmin(errs))
            if best is None or errs[k] < best[0]:
                best = (int(errs[k]), k, off, adj, seg)
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("result", type=Path, nargs="+")
    args = ap.parse_args()
    for path in args.result:
        d = json.loads(path.read_text())
        sf, cr = d["sf"], d["cr"]
        tpl = templates(sf, cr, d["templates"])
        n = tpl.shape[1]
        print(f"== {path.name}: SF{sf} CR4/{cr + 4}, {n} symbols per packet")
        for p in d["points"]:
            recs = [r for r in p["records"] if r.get("sym")]
            if not recs:
                print(f"SNR {p['snr_db']:+5.1f}: no symbol records")
                continue
            tot = err = pm1 = 0
            pos = np.zeros(n)
            for r in recs:
                raw = np.array([int(r["sym"][2 * i:2 * i + 2], 16) for i in range(len(r["sym"]) // 2)])
                pbin = 0 if r["realigned"] else r["pbin"]
                e, k, off, adj, seg = best_match(raw, pbin, tpl, sf)
                if e > n // 2:  # not this packet at all (a false or broken detection)
                    continue
                diff = (seg - tpl[k]) % (1 << sf)
                bad = diff != 0
                tot += n
                err += int(bad.sum())
                pm1 += int(((diff == 1) | (diff == (1 << sf) - 1)).sum())
                pos += bad
            ser = err / tot if tot else float("nan")
            th = ser_theory(sf, p["snr_db"])
            half = n // 2
            early = pos[:half].sum() / max(1, pos.sum())
            print(f"SNR {p['snr_db']:+5.1f}: PER {p['per']:.3f}; detected {len(recs)}; PL SER {ser:.4f} "
                  f"vs ideal {th:.4f} ({10 * np.log10(ser / th) if ser > 0 and th > 0 else float('nan'):+.1f} dB); "
                  f"+-1-bin share {pm1 / max(1, err):.2f}; errors in first half {early:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
