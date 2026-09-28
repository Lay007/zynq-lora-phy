#!/usr/bin/env python3
"""Build a LoRa test waveform with calibrated AWGN for the AD9361 transmitter.

A stream of packets in any SF/BW/CR at the board's 1 MS/s, each followed by a
gap, with circular Gaussian noise whose density gives exactly the requested SNR
*in the signal bandwidth BW* (the SX126x convention). The noise is band-limited
to +/-NOISE_EDGE_HZ so that it does not waste DAC range outside the receivers'
channel filters (the AD9361 RX analog filter is 200 kHz in the LoRa profile);
inside that band its density is flat, so SNR in BW is what the formula says.

Packets carry the Heltec test payload ('ZLP1', sequence, 4 bytes, sequence+i),
so every receiver's output can be matched to what was sent. The preamble is 12
upchirps, the sync word 0x12 two upchirps at 8 and 16, then 2.25 downchirps and
the symbols of the project's packet encoder (the inverse of the decoder that is
validated on real SX1262 packets).

Output: interleaved little-endian int16 I/Q (what iio_writedev takes for the
two DAC channels) and a JSON sidecar listing every packet's sequence number and
start sample.

    python tools/lora_tx_waveform.py --sf 7 --bw 125 --cr 1 --snr -6 \\
        --packets 200 --out wave_sf7_cr1_m6.iq
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from lora_per_ideal import ldro_required, test_payload  # noqa: E402
from zynq_lora_phy import encode_lora_packet  # noqa: E402
from zynq_lora_phy.css import CssConfig, modulate_symbol, reference_chirp  # noqa: E402

SAMPLE_RATE = 1_000_000
NOISE_EDGE_HZ = 150_000
PREAMBLE = 12
SYNC_WORD = 0x12


def chirp(n_chips: int, spc: int, symbol: int = 0, up: bool = True) -> np.ndarray:
    """One CSS symbol from the project's modulator (validated on SX1262 packets)."""

    config = CssConfig(spreading_factor=n_chips.bit_length() - 1, samples_per_chip=spc)
    if up:
        return modulate_symbol(symbol, config)
    return reference_chirp(config, up=False)


def packet_waveform(payload: bytes, sf: int, bw_hz: float, cr: int) -> np.ndarray:
    spc = int(round(SAMPLE_RATE / bw_hz))
    if spc * bw_hz != SAMPLE_RATE:
        raise ValueError("BW must divide 1 MS/s")
    n = 1 << sf
    ldro = ldro_required(sf, bw_hz / 1e3)
    symbols = encode_lora_packet(payload, spreading_factor=sf, coding_rate=cr,
                                 low_data_rate_optimization=ldro).symbols
    parts = [chirp(n, spc) for _ in range(PREAMBLE)]
    parts += [chirp(n, spc, (SYNC_WORD >> 4) * 8), chirp(n, spc, (SYNC_WORD & 0xF) * 8)]
    down = chirp(n, spc, up=False)
    parts += [down, down, down[: n * spc // 4]]
    parts += [chirp(n, spc, int(s)) for s in symbols]
    return np.concatenate(parts)


def bandlimited_noise(count: int, rng: np.random.Generator) -> np.ndarray:
    """Unit-density complex noise, flat inside +/-NOISE_EDGE_HZ, zero outside."""

    w = rng.standard_normal(count) + 1j * rng.standard_normal(count)
    spec = np.fft.fft(w)
    freqs = np.fft.fftfreq(count, 1 / SAMPLE_RATE)
    spec[np.abs(freqs) > NOISE_EDGE_HZ] = 0
    return np.fft.ifft(spec)  # per-sample variance 2 * (2*edge/fs) over the band


def build(sf: int, bw_khz: float, cr: int, snr_db: float, packets: int, gap_s: float,
          first_sequence: int, seed: int, rms_dbfs: float) -> tuple[np.ndarray, list[dict]]:
    rng = np.random.default_rng(seed)
    bw_hz = bw_khz * 1e3
    pieces, meta, cursor = [], [], 0
    gap = np.zeros(int(gap_s * SAMPLE_RATE), dtype=complex)
    for k in range(packets):
        seq = first_sequence + k
        w = packet_waveform(test_payload(seq), sf, bw_hz, cr)
        meta.append({"sequence": seq, "start_sample": cursor, "samples": int(w.size)})
        pieces += [w, gap]
        cursor += w.size + gap.size
    signal = np.concatenate(pieces)  # unit amplitude during packets
    # SNR in BW: signal power 1; noise density N0 with N0 * BW = 10^(-SNR/10).
    n0 = 10.0 ** (-snr_db / 10.0) / bw_hz
    noise = bandlimited_noise(signal.size, rng)
    unit_density = 2.0 / SAMPLE_RATE  # density of the raw N(0,1)+jN(0,1) noise
    noise *= np.sqrt(n0 / unit_density)
    x = signal + noise
    # Scale so the whole stream sits at rms_dbfs of int16 full scale.
    rms = np.sqrt(np.mean(np.abs(x) ** 2))
    x *= (32767.0 * 10 ** (rms_dbfs / 20.0)) / rms
    peak = np.max(np.abs(np.concatenate([x.real, x.imag])))
    if peak > 32767:
        raise ValueError(f"clipping: peak {peak:.0f}; lower --rms-dbfs")
    return x, meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--sf", type=int, default=7)
    ap.add_argument("--bw", type=float, default=125.0, help="kHz: 125, 250, 500 (divides 1 MS/s)")
    ap.add_argument("--cr", type=int, default=1, help="1..4 for 4/5..4/8")
    ap.add_argument("--snr", type=float, required=True, help="dB in the signal bandwidth")
    ap.add_argument("--packets", type=int, default=100)
    ap.add_argument("--gap", type=float, default=0.25, help="seconds of noise after each packet")
    ap.add_argument("--first-sequence", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--rms-dbfs", type=float, default=-14.0)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    x, meta = build(args.sf, args.bw, args.cr, args.snr, args.packets, args.gap,
                    args.first_sequence, args.seed, args.rms_dbfs)
    iq = np.empty(2 * x.size, dtype="<i2")
    iq[0::2] = np.round(x.real)
    iq[1::2] = np.round(x.imag)
    iq.tofile(args.out)
    sidecar = {
        "sf": args.sf, "bw_khz": args.bw, "cr": args.cr, "coding_rate": f"4/{args.cr + 4}",
        "snr_db_in_bw": args.snr, "sample_rate": SAMPLE_RATE, "noise_edge_hz": NOISE_EDGE_HZ,
        "preamble": PREAMBLE, "sync_word": SYNC_WORD, "payload_bytes": 32,
        "ldro": ldro_required(args.sf, args.bw), "rms_dbfs": args.rms_dbfs,
        "samples": int(x.size), "seconds": x.size / SAMPLE_RATE, "packets": meta,
    }
    args.out.with_suffix(args.out.suffix + ".json").write_text(json.dumps(sidecar, indent=1) + "\n")
    print(f"{args.out}: {x.size} samples, {x.size / SAMPLE_RATE:.2f} s, {len(meta)} packets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
