"""Stimulus and accounting for the SF7/L8 full-packet RTL regression.

Expected timestamps come from the injected waveform coordinates, never from
the receiver's detected window or decoded payload. These are simulation checks,
not an RF calibration or a statistical hardware qualification.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import re

import numpy as np

from tools.lora_tx_waveform import packet_waveform
from zynq_lora_phy import decode_lora_symbol_trace

SAMPLE_RATE_HZ = 1_000_000
BANDWIDTH_HZ = 125_000
SYMBOL_SAMPLES = 1024
TOA_LIMIT_SAMPLES = 0.5
HEADER_MARGIN_SAMPLES = 96


@dataclass(frozen=True)
class Case:
    phase: int
    cfo_hz: float
    preamble_symbols: int
    fractional_delay: float
    sfo_ppm: float = 0.0
    snr_db: float | None = None
    seed: int = 0

    @property
    def name(self) -> str:
        base = (f"phase{self.phase}-cfo{self.cfo_hz:g}-L{self.preamble_symbols}"
                f"-frac{self.fractional_delay:g}")
        if self.sfo_ppm or self.snr_db is not None:
            base += f"-sfo{self.sfo_ppm:g}-snr{self.snr_db}-seed{self.seed}"
        return base


def cases_for_suite(suite: str) -> list[Case]:
    baseline = [Case(*values) for values in (
        (508, 1500, 8, 0), (512, 1500, 12, 0), (0, 0, 8, 0),
        (0, 1500, 8, 0), (296, -1500, 8, 0), (512, -1500, 8, 0),
        (511, -1500, 12, 0), (700, 1500, 12, 0), (1023, -1500, 12, 0),
        (508, 418, 8, .25), (511, -418, 8, .5), (512, 1000, 12, .75),
        (1023, -1000, 12, .25), (512, 0, 8, 0), (508, -1000, 8, .25),
        (512, 418, 12, .5), (512, -418, 12, .75),
    )]
    if suite == "baseline":
        return baseline
    if suite != "timing":
        raise ValueError("unknown suite")
    # Paired signs and a clean control separate rate error from added noise.
    # Keep this small deterministic matrix distinct from a Monte Carlo study.
    return [Case(phase, cfo, preamble, fraction, sfo, snr, 1100 + index)
            for index, (phase, cfo, preamble, fraction) in enumerate((
                (511, -1000, 8, .25), (512, 1000, 12, .75),
                (0, -418, 12, .5), (1023, 418, 8, .25)))
            for sfo in (-20, 20) for snr in (None, 10.0)]


def resample_clock(samples: np.ndarray, sfo_ppm: float) -> np.ndarray:
    """Use the MATLAB channel convention: y[n] = x[n * (1 + ppm/1e6)].

    Linear interpolation matches apply_channel_impairments.m. Positive SFO
    compresses event coordinates. No filtering or clock-drift fitting is hidden.
    """
    rate = 1 + sfo_ppm * 1e-6
    if not np.isfinite(rate) or rate <= 0:
        raise ValueError("sample-rate ratio must be finite and positive")
    if sfo_ppm == 0:
        return samples.copy()
    axis = np.arange(len(samples))
    return np.interp(axis * rate, axis, samples, left=0, right=0)


def stimulus(case: Case, payload: bytes) -> tuple[np.ndarray, dict]:
    if case.preamble_symbols not in (8, 12):
        raise ValueError("only 8/12-symbol preambles are qualified")
    clean = packet_waveform(payload, 7, BANDWIDTH_HZ, 1)
    if case.preamble_symbols == 8:
        clean = clean[4 * SYMBOL_SAMPLES:]
    lead = 2048 + case.phase
    samples = np.pad(clean, (lead, 2048))
    if case.fractional_delay:
        # Preserve the baseline's bandlimited translation and zero guards.
        samples = np.fft.ifft(np.fft.fft(samples) * np.exp(
            -2j * np.pi * np.fft.fftfreq(len(samples)) * case.fractional_delay))
    samples = resample_clock(samples, case.sfo_ppm)
    samples *= np.exp(2j * np.pi * case.cfo_hz / SAMPLE_RATE_HZ * np.arange(len(samples)))
    if case.snr_db is not None:
        # Unit packet power, not mean power diluted by the silent guards.
        # White noise covers Fs; SNR is stated in BW, as on the PER bench.
        variance = SAMPLE_RATE_HZ / BANDWIDTH_HZ * 10 ** (-case.snr_db / 10)
        rng = np.random.default_rng(case.seed)
        samples += np.sqrt(variance / 2) * (
            rng.standard_normal(len(samples)) + 1j * rng.standard_normal(len(samples)))
    components = np.rint(np.column_stack((samples.real, samples.imag)) * 400)
    if np.any(np.abs(components) > 32767):
        raise ValueError("stimulus exceeds signed 16-bit range")
    components = components.astype(np.int64)
    words = ((components[:, 0] & 65535) << 16) | (components[:, 1] & 65535)
    rate = 1 + case.sfo_ppm * 1e-6
    truth = {
        "expected_origin_samples": (lead + case.fractional_delay
                                    + (case.preamble_symbols - 8) * SYMBOL_SAMPLES) / rate,
        "header_start_sample": (lead + case.fractional_delay
                                + (case.preamble_symbols + 4.25) * SYMBOL_SAMPLES) / rate,
        "input_samples": len(words),
    }
    return words, truth


def evaluate(case: Case, output: str, payload: bytes, truth: dict,
             returncode: int = 0) -> dict:
    detections = list(re.finditer(r"^DET .*", output, re.M))
    metadata = re.findall(r"^META (\d+) (-?\d+)$", output, re.M)
    latencies = re.findall(
        r"^LATENCY joint_total_clocks=(\d+) down_to_fine_clocks=(\d+) "
        r"n=(\d+) cfo_q12=(-?\d+) detection_to_fine_clocks=(\d+)$", output, re.M)
    done = re.findall(r"^DONE detected=(\d+) samples=(\d+)$", output, re.M)
    row = dict(asdict(case), **truth, detection_count=len(detections),
               metadata_count=len(metadata), latency_count=len(latencies),
               crc_valid=False, payload_match=False, toa_error_samples=None,
               simulator_returncode=returncode)
    failures = []
    if returncode != 0:
        failures.append("simulator_exit")
    if len(done) != 1 or tuple(map(int, done[0])) != (len(detections), truth["input_samples"]):
        failures.append("incomplete_trace")
    for name, records in (("detection_count", detections), ("metadata_count", metadata),
                          ("latency_count", latencies)):
        if len(records) != 1:
            failures.append(name)
    if detections:
        symbols = [int(s) for s in re.findall(r"^SYM (\d+) \d+$",
                                              output[detections[0].end():], re.M)]
        if symbols:
            decoded = decode_lora_symbol_trace(symbols, 0, require_payload_crc=True).result
            row.update(crc_valid=bool(decoded.crc_valid),
                       payload_match=bytes(decoded.payload) == payload)
    for name in ("crc_valid", "payload_match"):
        if not row[name]:
            failures.append(name)
    # Multiple records are ambiguous; never pick a favorable timestamp.
    if len(metadata) == 1:
        coarse, fraction = map(int, metadata[0])
        row.update(metadata_coarse=coarse, metadata_fractional_q12=fraction,
                   toa_error_samples=coarse + fraction / 4096 - truth["expected_origin_samples"])
        if not -2048 <= fraction <= 2048:
            failures.append("fractional_range")
        if abs(row["toa_error_samples"]) >= TOA_LIMIT_SAMPLES:
            failures.append("toa_error")
    if len(latencies) == 1:
        total, down, fine, cfo, detection_clocks = map(int, latencies[0])
        row.update(joint_clocks=total, down_to_fine_clocks=down,
                   prefetch_span_us_including_rf_wait=total / 62.5,
                   detection_to_fine_us=detection_clocks / 62.5,
                   fine_sample_count=fine, estimated_cfo_hz=-cfo / 4096 / 8192 * SAMPLE_RATE_HZ,
                   header_margin_samples=truth["header_start_sample"] - fine)
        if row["header_margin_samples"] <= HEADER_MARGIN_SAMPLES:
            failures.append("header_margin")
    row.update(failures=failures, passed=not failures)
    return row


def summarize(rows: list[dict], planned: int) -> dict:
    errors = np.array([r["toa_error_samples"] for r in rows
                       if r["toa_error_samples"] is not None], dtype=float)
    counts = {"planned": planned, "completed": len(rows),
              "passed": sum(r["passed"] for r in rows),
              "failed": sum(not r["passed"] for r in rows),
              "missing": planned - len(rows),
              "detection_misses": sum(r["detection_count"] == 0 for r in rows),
              "missing_metadata": sum(r["metadata_count"] == 0 for r in rows),
              "ambiguous_metadata": sum(r["metadata_count"] > 1 for r in rows),
              "crc_valid": sum(r["crc_valid"] for r in rows),
              "toa_observations": len(errors)}
    metrics = None
    if len(errors):
        metrics = {"bias_samples": float(np.mean(errors)),
                   "rmse_samples": float(np.sqrt(np.mean(errors ** 2))),
                   "abs_p95_samples": float(np.percentile(np.abs(errors), 95)),
                   "abs_p99_samples": float(np.percentile(np.abs(errors), 99)),
                   "max_abs_samples": float(np.max(np.abs(errors))),
                   "outliers": int(np.count_nonzero(np.abs(errors) >= TOA_LIMIT_SAMPLES))}
    return {"schema": "joint-packet-regression-v1", "counts": counts,
            "passed": len(rows) == planned and all(r["passed"] for r in rows),
            "limits": {"abs_toa_error_samples_exclusive": TOA_LIMIT_SAMPLES,
                       "header_margin_samples_exclusive": HEADER_MARGIN_SAMPLES},
            "toa": metrics,
            "interpretation": "Deterministic RTL simulation cases, not hardware accuracy or a PER estimate. "
                              "ToA statistics include every unambiguous timestamp, even CRC failures and outliers; "
                              "missing/ambiguous timestamps are counted separately. No bias or drift is fitted out."}
