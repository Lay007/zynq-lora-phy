#!/usr/bin/env python3
"""Ideal LoRa packet error rate against SNR, by Monte Carlo.

The reference the hardware receivers are compared with: a receiver that knows
the packet timing and has no carrier offset, decides each symbol by the peak of
the dechirped FFT (non-coherent, the optimum for CSS in AWGN), and then runs the
project's own packet decoder (Gray, diagonal deinterleave, Hamming, header
checksum, dewhitening, CRC-16). A packet counts as received only when the CRC is
valid *and* the payload bytes equal the ones sent.

SNR is defined in the signal bandwidth: one complex sample per chip at a sample
rate equal to BW, so the noise bandwidth equals the LoRa bandwidth and the
numbers compare directly with SX126x datasheet SNR limits. The packet is the
Heltec test packet: 32 bytes, explicit header, payload CRC on; low data rate
optimisation is on for SF11 and SF12 at 125 kHz, as the LoRa specification
requires. BW itself does not appear: at one sample per chip the baseband model
is identical for every bandwidth, only the time scale and the absolute
sensitivity (noise power 10*log10(BW) dB) change.

    python tools/lora_per_ideal.py --sf 7 8 9 10 11 12 --cr 1 2 3 4 \\
        --packets 1000 --out docs/data/lora_per_ideal.json
"""

from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from zynq_lora_phy import decode_lora_packet, encode_lora_packet  # noqa: E402
from zynq_lora_phy.css import CssConfig, reference_chirp  # noqa: E402

PAYLOAD_LENGTH = 32


def test_payload(sequence: int, length: int = PAYLOAD_LENGTH) -> bytes:
    """The Heltec firmware's counter payload: 'ZLP1', seq, millis, seq + i."""

    head = b"ZLP1" + int(sequence).to_bytes(4, "little") + int(sequence * 97).to_bytes(4, "little")
    body = bytes((sequence + i) & 0xFF for i in range(length - len(head)))
    return head + body


def ldro_required(spreading_factor: int, bandwidth_khz: float = 125.0) -> bool:
    """LoRa mandates low data rate optimisation when a symbol exceeds 16 ms."""

    return (1 << spreading_factor) / bandwidth_khz > 16.0


def symbol_error_matrix(symbols: np.ndarray, sf: int, snr_db: float,
                        rng: np.random.Generator) -> np.ndarray:
    """Demodulate a (packets x symbols) matrix of CSS symbols through AWGN."""

    config = CssConfig(spreading_factor=sf, samples_per_chip=1)
    n = config.symbol_count
    up = reference_chirp(config, up=True)
    # Symbol k is the base upchirp cyclically shifted by k chips.
    idx = (np.arange(n)[None, None, :] + symbols[:, :, None]) % n
    tx = up[idx]
    noise_power = 10.0 ** (-snr_db / 10.0)  # |up| = 1 per sample
    noise = np.sqrt(noise_power / 2.0) * (
        rng.standard_normal(tx.shape) + 1j * rng.standard_normal(tx.shape))
    rx = (tx + noise) * np.conj(up)[None, None, :]
    return np.argmax(np.abs(np.fft.fft(rx, axis=2)), axis=2)


def run_point(args: tuple[int, int, float, int, int]) -> dict[str, float]:
    sf, cr, snr_db, packets, seed = args
    rng = np.random.default_rng(seed)
    ldro = ldro_required(sf)
    payloads = [test_payload(seed * 7919 + p) for p in range(packets)]
    encoded = [encode_lora_packet(p, spreading_factor=sf, coding_rate=cr,
                                  low_data_rate_optimization=ldro).symbols for p in payloads]
    length = len(encoded[0])
    sent = np.array(encoded, dtype=np.int64)
    # In batches: SF12 x 1000 packets x 64 symbols x 4096 samples is 4 GB.
    got = np.concatenate([symbol_error_matrix(sent[i:i + 50], sf, snr_db, rng)
                          for i in range(0, packets, 50)])
    ok = 0
    for i in range(packets):
        result = decode_lora_packet(got[i].tolist(), spreading_factor=sf,
                                    low_data_rate_optimization=ldro)
        if result.success and result.crc_valid and bytes(result.payload) == payloads[i]:
            ok += 1
    return {
        "sf": sf, "cr": cr, "snr_db": snr_db, "packets": packets,
        "per": 1.0 - ok / packets,
        "ser": float(np.mean(got != sent)),
        "symbols_per_packet": length,
    }


def snr_grid(sf: int, step: float) -> list[float]:
    # The SX126x demodulator limits are -7.5 dB (SF7) .. -20 dB (SF12),
    # 2.5 dB per SF; sweep 8 dB below to 4 dB above.
    centre = -7.5 - 2.5 * (sf - 7)
    return [round(v, 2) for v in np.arange(centre - 8.0, centre + 4.0 + 1e-9, step)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--sf", type=int, nargs="+", default=[7])
    ap.add_argument("--cr", type=int, nargs="+", default=[1], help="1..4 for 4/5..4/8")
    ap.add_argument("--packets", type=int, default=1000)
    ap.add_argument("--step", type=float, default=0.5)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    jobs = [(sf, cr, snr, args.packets, 1000 * sf + 100 * cr + i)
            for sf in args.sf for cr in args.cr for i, snr in enumerate(snr_grid(sf, args.step))]
    rows = []
    with ProcessPoolExecutor(args.workers) as pool:
        for row in pool.map(run_point, jobs):
            rows.append(row)
            print(f"SF{row['sf']} CR4/{row['cr'] + 4} SNR {row['snr_db']:+6.1f} dB  "
                  f"PER {row['per']:.4f}  SER {row['ser']:.4f}", flush=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({
        "description": "ideal LoRa PER/SER vs SNR in the signal bandwidth (Monte Carlo, "
                       "perfect timing, no CFO, non-coherent FFT decision, project decoder)",
        "payload_bytes": PAYLOAD_LENGTH, "explicit_header": True, "payload_crc": True,
        "rows": rows}, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
