#!/usr/bin/env python3
"""Plot the ideal LoRa curves and check the Monte Carlo model against theory.

1. docs/figures/per_ideal.png -- packet error rate against SNR (in the signal
   bandwidth), one panel per coding rate, one line per SF, from
   docs/data/lora_per_ideal.json (tools/lora_per_ideal.py). Measured receivers
   (tools/per_measure.py results given with --measured) are drawn on top.
2. docs/figures/ser_model_vs_theory.png -- the model's symbol error rate
   against the exact non-coherent M-ary orthogonal result. After dechirping,
   the 2^SF LoRa symbols are orthogonal tones, so with perfect timing the
   correct bin's envelope is Rician and the other M-1 are Rayleigh:

     P_c = integral r exp(-(r^2 + a^2)/2) I0(a r) (1 - exp(-r^2/2))^(M-1) dr,
     a^2 = 2 Es/N0,   Es/N0 = M * SNR   (SNR in the signal bandwidth),

   evaluated numerically (the alternating closed-form sum is unstable at
   M = 4096). If the model's SER lies on these lines, the Monte Carlo curves
   rest on a correct symbol layer and the packet layer is the only thing the
   PER adds.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
# Reference categorical palette (dataviz skill), slots 1..6, validated for
# lines on the light surface; three slots sit below 3:1, so every line is
# also direct-labelled.
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
GRID = "#e4e3df"


def i0e(x: np.ndarray) -> np.ndarray:
    """exp(-|x|) I0(x) without SciPy: numpy.i0 below 30, the asymptotic series above."""

    x = np.abs(np.asarray(x, dtype=float))
    out = np.empty_like(x)
    small = x < 30.0
    out[small] = np.i0(x[small]) * np.exp(-x[small])
    xl = x[~small]
    out[~small] = (1.0 + 1.0 / (8 * xl) + 9.0 / (128 * xl ** 2) + 225.0 / (3072 * xl ** 3)) / np.sqrt(2 * np.pi * xl)
    return out


def ser_theory(sf: int, snr_db: float) -> float:
    m = 1 << sf
    es_n0 = m * 10.0 ** (snr_db / 10.0)
    a = np.sqrt(2.0 * es_n0)
    r = np.linspace(max(0.0, a - 12.0), a + 12.0, 6001)
    pdf = r * np.exp(-0.5 * (r - a) ** 2) * i0e(a * r)  # Rician, scaled I0
    # (1 - exp(-r^2/2))^(M-1), computed in logs
    with np.errstate(divide="ignore"):
        wrong = np.exp((m - 1) * np.log1p(-np.exp(-0.5 * np.maximum(r, 1e-9) ** 2)))
    pc = np.trapezoid(pdf * wrong, r)
    return float(max(0.0, 1.0 - pc))


def style(ax) -> None:
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(INK2)
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=INK2, labelsize=8)
    ax.grid(True, which="major", color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)


def label_at(ax, xs, ys, text, color, target=0.1) -> None:
    """Direct label where the curve crosses `target` (text in ink, mark in colour)."""
    pts = [(x, y) for x, y in zip(xs, ys) if y > 0]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if y0 >= target >= y1:
            f = (np.log(y0) - np.log(target)) / (np.log(y0) - np.log(y1)) if y1 > 0 else 0
            x = x0 + f * (x1 - x0)
            ax.plot([x], [target], "o", ms=4, color=color, mec=SURFACE, mew=1.5, zorder=4)
            ax.annotate(text, (x, target), xytext=(3, 4), textcoords="offset points",
                        fontsize=7.5, color=INK, zorder=5)
            return


def plot_per(rows, measured, out: Path) -> None:
    g = defaultdict(list)
    for r in rows:
        g[(r["sf"], r["cr"])].append((r["snr_db"], r["per"]))
    fig, axes = plt.subplots(2, 2, figsize=(10, 7.2), sharex=True, sharey=True, facecolor=SURFACE)
    floor = 5e-4
    for ax, cr in zip(axes.flat, (1, 2, 3, 4)):
        style(ax)
        for i, sf in enumerate(range(7, 13)):
            pts = sorted(g[(sf, cr)])
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            ax.plot(xs, [max(y, floor) if y > 0 else np.nan for y in ys], color=SERIES[i], lw=2,
                    solid_capstyle="round", label=f"SF{sf}")
            label_at(ax, xs, ys, f"SF{sf}", SERIES[i])
        for m in measured:
            if m["cr"] != cr:
                continue
            i = m["sf"] - 7
            xs = [p["snr_db"] for p in m["points"] if p.get("per") is not None]
            ys = [max(p["per"], floor) for p in m["points"] if p.get("per") is not None]
            ax.plot(xs, ys, linestyle="none", marker={"pl": "s"}.get(m["receiver"].lower(), "^"),
                    ms=8, mfc=SURFACE, mec=SERIES[i], mew=2, zorder=5)
        ax.set_yscale("log")
        ax.set_ylim(floor, 1.2)
        ax.set_xlim(-26, -3)
        ax.set_title(f"CR 4/{cr + 4}", fontsize=10, color=INK, loc="left")
    for ax in axes[1]:
        ax.set_xlabel("SNR in the signal bandwidth, dB", fontsize=9, color=INK2)
    for ax in axes[:, 0]:
        ax.set_ylabel("packet error rate", fontsize=9, color=INK2)
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=6, frameon=False, fontsize=9,
               bbox_to_anchor=(0.5, 0.965), labelcolor=INK)
    fig.suptitle("Ideal LoRa receiver: packet error rate vs SNR (32-byte payload, explicit header, CRC)",
                 fontsize=11, color=INK, x=0.01, ha="left", y=0.995)
    fig.text(0.01, 0.005, "Monte Carlo, 1000 packets per point, 0.5 dB steps; perfect timing, no CFO. "
             "Points below 5e-4 (0 errors) are not drawn. Dots mark PER = 10 %.",
             fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.02, 1, 0.94))
    fig.savefig(out, dpi=150, facecolor=SURFACE)
    plt.close(fig)


def plot_ser(rows, out: Path) -> dict:
    g = defaultdict(list)
    for r in rows:
        if r["cr"] == 1:
            g[r["sf"]].append((r["snr_db"], r["ser"], r["packets"] * r["symbols_per_packet"]))
    fig, ax = plt.subplots(figsize=(9.4, 5.2), facecolor=SURFACE)
    style(ax)
    theory = {}
    worst = 0.0
    for i, sf in enumerate(range(7, 13)):
        pts = sorted(g[sf])
        grid = np.linspace(pts[0][0], pts[-1][0], 80)
        t = [ser_theory(sf, s) for s in grid]
        theory[sf] = {"snr_db": [round(float(s), 3) for s in grid], "ser": t}
        ax.plot(grid, [max(v, 1e-6) for v in t], color=SERIES[i], lw=2, label=f"SF{sf}")
        xs = [p[0] for p in pts if p[1] > 0]
        ys = [p[1] for p in pts if p[1] > 0]
        ax.plot(xs, ys, linestyle="none", marker="o", ms=4.5, mfc=SURFACE, mec=SERIES[i], mew=1.5)
        for s, ser, n in pts:
            th = ser_theory(sf, s)
            if th > 2e-3 and ser > 0:  # enough errors for a meaningful ratio
                worst = max(worst, abs(10 * np.log10(ser / th)))
        label_at(ax, list(grid), t, f"SF{sf}", SERIES[i], target=1e-2)
    ax.set_yscale("log")
    ax.set_ylim(1e-5, 1)
    ax.set_xlabel("SNR in the signal bandwidth, dB", fontsize=9, color=INK2)
    ax.set_ylabel("symbol error rate", fontsize=9, color=INK2)
    ax.legend(frameon=False, fontsize=8.5, ncol=1, loc="upper left", bbox_to_anchor=(1.01, 1.0), labelcolor=INK)
    ax.set_title("Symbol error rate: exact non-coherent theory (lines) vs the Monte Carlo model (circles)",
                 fontsize=10.5, color=INK, loc="left")
    fig.text(0.01, 0.01, f"Theory: M-ary orthogonal non-coherent detection, Es/N0 = 2^SF x SNR. "
             f"Largest model/theory gap where SER > 2e-3: {worst:.2f} dB of SER ratio.",
             fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(out, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    return {"theory": theory, "worst_ser_ratio_db": worst}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ideal", type=Path, default=ROOT / "docs/data/lora_per_ideal.json")
    ap.add_argument("--measured", type=Path, nargs="*", default=[])
    ap.add_argument("--outdir", type=Path, default=ROOT / "docs/figures")
    args = ap.parse_args()
    rows = json.loads(args.ideal.read_text())["rows"]
    measured = [json.loads(p.read_text()) for p in args.measured]
    args.outdir.mkdir(parents=True, exist_ok=True)
    plot_per(rows, measured, args.outdir / "per_ideal.png")
    ser = plot_ser(rows, args.outdir / "ser_model_vs_theory.png")
    (ROOT / "docs/data/lora_ser_theory.json").write_text(json.dumps(ser, indent=1) + "\n")
    print(f"worst model/theory SER ratio: {ser['worst_ser_ratio_db']:.3f} dB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
