#!/usr/bin/env python3
"""Float model of PL packet detection on the free-running 1024-sample grid (#36).

Each trial places the PER-bench packet (tools/lora_tx_waveform.packet_waveform: preamble 12, sync
0x12, SFD, payload) at a random sample phase in AWGN at the set SNR (in 125 kHz, white over the
1 MS/s band, as board/per/lora_tx_noise does). Decisions come from the correlator identity
(zynq_lora_phy.css.fft_correlator_stages) on consecutive 1024-sample windows. CFO is zero, as on the
bench, where TX and RX share a reference.

Rules compared:

  preamble8  8 consecutive decisions within +-1 of each other. The board's measured missed-detection
             rate matches this bound (0.105-0.14 at -8.5 dB against 0.11-0.12 here), i.e. with all
             its sync paths the board detects exactly when the preamble gives 8 equal decisions.
  accum      |X|^2 summed over the last K=8 windows; trigger when the largest accumulated bin is
             above t times the mean of the others. Noise-only, each bin of the sum is Gamma(K), so
             t follows from 128 * Q_K(t*K) = P_fa (4.41 for P_fa 1e-6 per window, ~1 per 17 min).
             On the trigger the live grid moves by (M - round(8*(k + frac))) mod M samples, k the
             accumulated peak bin and frac a parabolic estimate from its neighbours, so the next
             windows sit on symbol boundaries; the sync pair is then read there: two consecutive
             decisions at ref+8*hi and ref+8*lo (+-1), ref in {0, +-1}, within 18 windows.

    python tools/lora_detection_model.py --trials 300 --snr -11 -10 -9 -8.5 -8
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

from lora_per_ideal import test_payload  # noqa: E402
from lora_tx_waveform import packet_waveform  # noqa: E402
from zynq_lora_phy.css import CssConfig, fft_correlator_stages  # noqa: E402

CFG = CssConfig(spreading_factor=7, samples_per_chip=8)
M, N = 1024, 128
SYNC = 0x12
HI, LO = (SYNC >> 4) * 8, (SYNC & 15) * 8


def within(a: int, b: int, tol: int = 1) -> bool:
    return abs((a - b + N // 2) % N - N // 2) <= tol


def accumulation_threshold(k: int, p_fa: float) -> float:
    """t with N * P(Gamma(k) > t*k) = p_fa, in units of the mean bin power."""

    def tail(x: float) -> float:
        return math.exp(-x) * sum(x ** i / math.factorial(i) for i in range(k))

    lo, hi = 0.0, 400.0
    for _ in range(100):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if N * tail(mid) > p_fa else (lo, mid)
    return hi / k


def windows(x: np.ndarray):
    n = len(x) // M
    st = fft_correlator_stages(x[: n * M].reshape(n, M), CFG)
    return st.symbols, st.magnitude_squared


def preamble8(sym: np.ndarray) -> bool:
    return any(all(within(sym[j], sym[i - 8]) for j in range(i - 8, i)) for i in range(8, len(sym) + 1))


def accumulated_live(x: np.ndarray, k_windows: int, threshold: float) -> bool:
    sym, mag = windows(x)
    for i in range(k_windows, len(mag) + 1):
        acc = mag[i - k_windows:i].sum(0)
        pk = acc.max()
        if pk / ((acc.sum() - pk) / (N - 1)) <= threshold:
            continue
        k = int(acc.argmax())
        a_m, a_0, a_p = np.sqrt(acc[[(k - 1) % N, k, (k + 1) % N]])
        den = a_m - 2 * a_0 + a_p
        frac = 0.5 * (a_m - a_p) / den if den else 0.0
        shift = int(round((k + frac) * CFG.samples_per_chip))
        start = i * M + (M - shift) % M
        asym, _ = windows(x[start:])
        for ref in (0, 1, N - 1):
            # a strong preamble triggers after only a few of its 12 symbols: up to ~11 more
            # preamble windows may come before the sync pair, so the scan covers 18 windows
            for j in range(min(len(asym) - 1, 18)):
                if within(asym[j], ref + HI) and within(asym[j + 1], ref + LO):
                    return True
        return False
    return False


def trial(rng: np.random.Generator, snr_db: float) -> np.ndarray:
    w = packet_waveform(test_payload(int(rng.integers(64))), 7, 125e3, 1, 1e6)
    phase = int(rng.integers(0, M))
    total = 30 * M
    x = np.zeros(total, complex)
    x[4 * M + phase:] = w[: total - 4 * M - phase]
    sigma = math.sqrt(10 ** (-snr_db / 10) / 125e3 * 1e6 / 2)
    return x + sigma * (rng.standard_normal(total) + 1j * rng.standard_normal(total))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--trials", type=int, default=300)
    ap.add_argument("--snr", type=float, nargs="+", default=[-11, -10, -9, -8.5, -8, -7])
    ap.add_argument("--k", type=int, default=8)
    ap.add_argument("--p-fa", type=float, default=1e-6)
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()
    t = accumulation_threshold(args.k, args.p_fa)
    print(f"K={args.k}, P_fa {args.p_fa:g}/window: threshold {t:.2f} x mean bin power")
    rng = np.random.default_rng(args.seed)
    for snr in args.snr:
        miss = np.zeros(2)
        for _ in range(args.trials):
            x = trial(rng, snr)
            sym, _ = windows(x)
            miss += [not preamble8(sym), not accumulated_live(x, args.k, t)]
        print(f"SNR {snr:+.1f} dB: missed, preamble8 {miss[0] / args.trials:.3f}, "
              f"accumulated + live resync {miss[1] / args.trials:.3f}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
