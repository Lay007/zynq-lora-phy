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


FRAC_MODE = "amp"


def fractional_chip(p3: np.ndarray, mode: str) -> float:
    """Sub-chip offset of the accumulated peak from its two neighbours: 'amp' parabola on
    amplitudes (needs square roots), 'pow' parabola on powers (hardware-cheap), 'none'."""
    if mode == "none":
        return 0.0
    v = np.sqrt(p3) if mode == "amp" else p3.astype(float)
    den = v[0] - 2 * v[1] + v[2]
    return float(np.clip(0.5 * (v[0] - v[2]) / den, -0.5, 0.5)) if den else 0.0


def accumulated_live(x: np.ndarray, k_windows: int, threshold: float, sync1_sample: int | None = None,
                     require_preamble: bool = False) -> str:
    """'ok' when the sync pair is accepted on the true sync windows, 'wrong' when a pair of noise or
    payload decisions is accepted elsewhere first (a detection with the wrong timing, the packet
    is lost), 'miss' otherwise. require_preamble adds the window before the pair: it must read the
    preamble (ref +-1). Windows are scanned in time order, all three references per window, as the
    RTL does."""
    sym, mag = windows(x)
    for i in range(k_windows, len(mag) + 1):
        acc = mag[i - k_windows:i].sum(0)
        pk = acc.max()
        if pk / ((acc.sum() - pk) / (N - 1)) <= threshold:
            continue
        k = int(acc.argmax())
        frac = fractional_chip(acc[[(k - 1) % N, k, (k + 1) % N]], FRAC_MODE)
        shift = int(round((k + frac) * CFG.samples_per_chip))
        start = i * M + (M - shift) % M
        asym, _ = windows(x[start:])
        # a strong preamble triggers after only a few of its 12 symbols: up to ~11 more preamble
        # windows may come before the sync pair, so the scan covers 18 windows
        for j in range(min(len(asym) - 1, 18)):
            for ref in (0, 1, N - 1):
                pre_ok = (not require_preamble) or (j > 0 and within(asym[j - 1], ref))
                if pre_ok and within(asym[j], ref + HI) and within(asym[j + 1], ref + LO):
                    if sync1_sample is None:
                        return "ok"
                    true_j = int(round((sync1_sample - start) / M))
                    return "ok" if j == true_j else "wrong"
        return "miss"
    return "miss"


def trial(rng: np.random.Generator, snr_db: float) -> tuple[np.ndarray, int]:
    """The noisy stream and the sample where the first sync symbol starts."""
    w = packet_waveform(test_payload(int(rng.integers(64))), 7, 125e3, 1, 1e6)
    phase = int(rng.integers(0, M))
    total = 30 * M
    x = np.zeros(total, complex)
    s0 = 4 * M + phase
    x[s0:] = w[: total - s0]
    sigma = math.sqrt(10 ** (-snr_db / 10) / 125e3 * 1e6 / 2)
    x = x + sigma * (rng.standard_normal(total) + 1j * rng.standard_normal(total))
    return x, s0 + 12 * M  # preamble of 12 upchirps (lora_tx_waveform.PREAMBLE)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--trials", type=int, default=300)
    ap.add_argument("--snr", type=float, nargs="+", default=[-11, -10, -9, -8.5, -8, -7])
    ap.add_argument("--k", type=int, default=8)
    ap.add_argument("--p-fa", type=float, default=1e-6)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--frac", choices=["amp", "pow", "none"], default="amp")
    args = ap.parse_args()
    global FRAC_MODE
    FRAC_MODE = args.frac
    t = accumulation_threshold(args.k, args.p_fa)
    print(f"K={args.k}, P_fa {args.p_fa:g}/window: threshold {t:.2f} x mean bin power")
    rng = np.random.default_rng(args.seed)
    for snr in args.snr:
        counts = {"pre8": 0, "ok": 0, "wrong": 0, "ok_p": 0, "wrong_p": 0}
        for _ in range(args.trials):
            x, sync1 = trial(rng, snr)
            sym, _ = windows(x)
            counts["pre8"] += not preamble8(sym)
            r = accumulated_live(x, args.k, t, sync1)
            counts["ok"] += r == "ok"
            counts["wrong"] += r == "wrong"
            r = accumulated_live(x, args.k, t, sync1, require_preamble=True)
            counts["ok_p"] += r == "ok"
            counts["wrong_p"] += r == "wrong"
        n = args.trials
        print(f"SNR {snr:+.1f} dB: missed, preamble8 {counts['pre8'] / n:.3f}; accumulated + live resync "
              f"{1 - counts['ok'] / n:.3f} (wrong timing {counts['wrong'] / n:.3f}); with the preamble window "
              f"{1 - counts['ok_p'] / n:.3f} (wrong timing {counts['wrong_p'] / n:.3f})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
