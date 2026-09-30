#!/usr/bin/env python3
"""Stimulus and expected results for fpga/tb/tb_lora_preamble_accumulator.sv (#36).

Each case is a bench packet (tools/lora_tx_waveform.packet_waveform) at a known sample phase in
AWGN, scaled to a given ADC noise RMS and rounded like the ADC. Per-bin |X|^2 of every 1024-sample
window comes from the correlator identity and is written in the M11 core's binPower units
(ufix40_En19 of |FFT_N/M|^2 with the input at v*2^-10). The expected trigger follows the RTL's
integer rules exactly: powers >> 8 (saturated to 32 bits), sums over the last 8 windows,
127*peak*100 > 441*(total - peak) on the first full window that satisfies it, q = round(8*f) from
the power parabola, skip = (1024 - (8*k + q)) mod 1024.

Output (fpga/tb/vectors/preamble_accumulator/): case_<n>.hex, one line per bin '<power 40-bit
hex> <bin>', windows back to back; expected.txt, '<case> <trigger window or -1> <bin> <q> <skip>'.
"""

from __future__ import annotations

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
M, N, K = 1024, 128, 8
OUT = ROOT / "fpga/tb/vectors/preamble_accumulator"

# (snr_db, phase, noise_rms_lsb, seed): strong, weak, mid-chip phase, silence
CASES = [(10.0, 0, 57.0, 1), (-9.0, 300, 57.0, 2), (-9.0, 612, 6.0, 3), (0.0, 1020, 20.0, 4),
         (None, 0, 57.0, 5)]


def windows_power(v: np.ndarray) -> np.ndarray:
    n = len(v) // M
    st = fft_correlator_stages(v[: n * M].reshape(n, M) * 2.0 ** -10, CFG)
    return np.floor(st.magnitude_squared * 2.0 ** 19).astype(np.int64)  # ufix40_En19


def expected(p40: np.ndarray):
    p = np.minimum(p40 >> 8, 2 ** 32 - 1)
    for i in range(K, len(p) + 1):
        acc = p[i - K:i].sum(0)
        k = int(acc.argmax())  # first maximum, as the RTL's strict '>'
        tot = int(acc.sum())
        if 127 * int(acc[k]) * 100 > 441 * (tot - int(acc[k])):
            pm, p0, pp = int(acc[(k - 1) % N]), int(acc[k]), int(acc[(k + 1) % N])
            num, den2 = pm - pp, 2 * (2 * p0 - pm - pp)
            q = 0
            if den2 > 0:
                for j in range(1, 5):
                    if num * 8 * 2 > den2 * (2 * j - 1):
                        q = j
                    if num * 8 * 2 < -den2 * (2 * j - 1):
                        q = -j
            skip = (M - (8 * k + q)) % M
            return i - 1, k, q, skip
    return -1, 0, 0, 0


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    lines = []
    for n, (snr, phase, rms, seed) in enumerate(CASES):
        rng = np.random.default_rng(seed)
        total = 24 * M
        x = np.zeros(total, complex)
        if snr is not None:
            w = packet_waveform(test_payload(n), 7, 125e3, 1, 1e6)
            x[4 * M + phase:] = w[: total - 4 * M - phase]
            sigma = np.sqrt(10 ** (-snr / 10) / 125e3 * 1e6 / 2)
        else:
            sigma = 1.0
        x = x + sigma * (rng.standard_normal(total) + 1j * rng.standard_normal(total))
        noise_rms = sigma * np.sqrt(2)
        v = x * (rms / noise_rms)
        v = np.round(v.real) + 1j * np.round(v.imag)
        p40 = windows_power(v)
        with open(OUT / f"case_{n}.hex", "w") as f:
            for win in p40:
                for b, val in enumerate(win):
                    f.write(f"{int(val) & (2 ** 40 - 1):010x} {b:02x}\n")
        e = expected(p40)
        lines.append(f"{n} {e[0]} {e[1]} {e[2]} {e[3]} {len(p40)}")
        print(f"case {n}: snr {snr} phase {phase} rms {rms}: trigger window {e[0]}, bin {e[1]}, q {e[2]}, skip {e[3]}")
    (OUT / "expected.txt").write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
