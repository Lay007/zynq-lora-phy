#!/usr/bin/env python3
"""Compare equal-resource LFM, NLFM, and optimized FM positioning pulses."""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np

from zynq_lora_phy.fm_positioning import (
    SPEED_OF_LIGHT_M_S,
    FmWaveform,
    FmWaveformConfig,
    ParetoCandidate,
    ParetoSearchResult,
    ambiguity_peak,
    autocorrelation_metrics,
    delay_crlb_std_s,
    make_lfm_waveform,
    make_sinusoidal_nlfm_waveform,
    monte_carlo_paired_toa,
    monte_carlo_toa,
    optimize_harmonic_fm,
    paired_ambiguity_estimate,
    rms_bandwidth_hz,
    search_pareto_harmonic_fm,
)


ROOT = Path(__file__).resolve().parents[1]


def _git_provenance() -> dict[str, Any]:
    def git(*arguments: str) -> str:
        result = subprocess.run(
            ["git", *arguments],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    try:
        commit = git("rev-parse", "HEAD")
        branch = git("branch", "--show-current")
        dirty = bool(git("status", "--porcelain"))
    except (OSError, subprocess.CalledProcessError):
        commit, branch, dirty = "unavailable", "unavailable", None
    return {"commit": commit, "branch": branch, "dirty": dirty}


def _metric_row(
    waveform: FmWaveform,
    config: FmWaveformConfig,
    *,
    crlb_snr_db: float,
    mobile_doppler_hz: float,
) -> dict[str, Any]:
    energy = float(np.vdot(waveform.samples, waveform.samples).real)
    rms_bandwidth = rms_bandwidth_hz(waveform)
    crlb_s = delay_crlb_std_s(waveform, crlb_snr_db)
    correlation = autocorrelation_metrics(waveform, config.sample_rate_hz)
    mobile_peak = ambiguity_peak(
        waveform, config.sample_rate_hz, mobile_doppler_hz
    )
    return {
        "waveform": waveform.name,
        "harmonic_coefficients": ";".join(
            f"{value:.12g}" for value in waveform.harmonic_coefficients
        ),
        "duration_us": 1e6 * waveform.samples.size / config.sample_rate_hz,
        "swept_bandwidth_hz": float(
            waveform.instantaneous_frequency_hz[-1]
            - waveform.instantaneous_frequency_hz[0]
        ),
        "energy": energy,
        "rms_bandwidth_hz": rms_bandwidth,
        "delay_crlb_snr_db": crlb_snr_db,
        "delay_crlb_std_ns": 1e9 * crlb_s,
        "one_way_crlb_std_m": SPEED_OF_LIGHT_M_S * crlb_s,
        "mainlobe_width_samples": correlation.mainlobe_width_samples,
        "mainlobe_width_us": 1e6 * correlation.mainlobe_width_s,
        "peak_sidelobe_db": correlation.peak_sidelobe_db,
        "integrated_sidelobe_db": correlation.integrated_sidelobe_db,
        "mobile_doppler_hz": mobile_doppler_hz,
        "mobile_peak_delay_samples": mobile_peak.delay_samples,
        "mobile_peak_bias_m": (
            SPEED_OF_LIGHT_M_S
            * mobile_peak.delay_samples
            / config.sample_rate_hz
        ),
        "mobile_peak_loss_db": 20.0
        * np.log10(max(mobile_peak.normalized_magnitude, np.finfo(float).tiny)),
    }


def _ambiguity_rows(
    waveforms: list[FmWaveform],
    config: FmWaveformConfig,
    dopplers_hz: list[float],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for waveform in waveforms:
        for doppler_hz in dopplers_hz:
            peak = ambiguity_peak(waveform, config.sample_rate_hz, doppler_hz)
            rows.append(
                {
                    "waveform": waveform.name,
                    "doppler_hz": peak.doppler_hz,
                    "peak_delay_samples": peak.delay_samples,
                    "peak_delay_us": 1e6
                    * peak.delay_samples
                    / config.sample_rate_hz,
                    "one_way_bias_m": SPEED_OF_LIGHT_M_S
                    * peak.delay_samples
                    / config.sample_rate_hz,
                    "normalized_peak": peak.normalized_magnitude,
                    "peak_loss_db": 20.0
                    * np.log10(
                        max(peak.normalized_magnitude, np.finfo(float).tiny)
                    ),
                }
            )
    return rows


def _monte_carlo_rows(
    waveforms: list[FmWaveform],
    config: FmWaveformConfig,
    *,
    snr_values_db: list[float],
    trials: int,
    seed: int,
    mobile_doppler_hz: float,
) -> list[dict[str, Any]]:
    conditions = [(snr, 0.0) for snr in snr_values_db]
    conditions.append((max(snr_values_db), mobile_doppler_hz))
    rows: list[dict[str, Any]] = []
    for condition_index, (snr_db, doppler_hz) in enumerate(conditions):
        condition_seed = seed + 10_000 * condition_index
        for waveform in waveforms:
            # Resetting to the same condition seed gives every waveform the
            # same Gaussian draws, reducing comparison variance.
            result = monte_carlo_toa(
                waveform,
                config,
                energy_snr_db=snr_db,
                trials=trials,
                rng=np.random.default_rng(condition_seed),
                doppler_hz=doppler_hz,
            )
            crlb_samples = (
                delay_crlb_std_s(waveform, snr_db) * config.sample_rate_hz
            )
            rows.append(
                {
                    "waveform": waveform.name,
                    "energy_snr_db": result.snr_db,
                    "doppler_hz": result.doppler_hz,
                    "trials": result.trials,
                    "bias_samples": result.bias_samples,
                    "rmse_samples": result.rmse_samples,
                    "rmse_m": SPEED_OF_LIGHT_M_S
                    * result.rmse_samples
                    / config.sample_rate_hz,
                    "crlb_std_samples": crlb_samples,
                    "crlb_std_m": SPEED_OF_LIGHT_M_S
                    * crlb_samples
                    / config.sample_rate_hz,
                    "outlier_rate": result.outlier_rate,
                }
            )
    return rows


def _coefficient_key(candidate: ParetoCandidate) -> tuple[float, ...]:
    return tuple(round(value, 12) for value in candidate.waveform.harmonic_coefficients)


def _select_pareto_representatives(
    search: ParetoSearchResult,
) -> dict[str, ParetoCandidate]:
    front = list(search.front)
    objective_matrix = np.asarray(
        [
            (
                candidate.delay_variance_ratio,
                candidate.peak_sidelobe_amplitude_ratio,
                candidate.integrated_sidelobe_energy_ratio,
                candidate.doppler_coupling_ratio,
            )
            for candidate in front
        ],
        dtype=np.float64,
    )
    log_objectives = np.log10(objective_matrix)
    spans = np.maximum(
        np.ptp(log_objectives, axis=0), np.finfo(np.float64).eps
    )
    normalized = (log_objectives - np.min(log_objectives, axis=0)) / spans
    knee = front[int(np.argmin(np.linalg.norm(normalized, axis=1)))]
    lfm = min(
        front,
        key=lambda candidate: sum(
            coefficient**2 for coefficient in candidate.waveform.harmonic_coefficients
        ),
    )
    delay = min(front, key=lambda candidate: candidate.delay_variance_ratio)
    sidelobe = min(
        front,
        key=lambda candidate: np.sqrt(
            candidate.peak_sidelobe_amplitude_ratio
            * candidate.integrated_sidelobe_energy_ratio
        ),
    )
    return {
        "lfm": lfm,
        "balanced_knee": knee,
        "delay_focused": delay,
        "sidelobe_focused": sidelobe,
    }


def _pareto_rows(
    search: ParetoSearchResult,
    selections: dict[str, ParetoCandidate],
) -> list[dict[str, Any]]:
    front_ids = {id(candidate) for candidate in search.front}
    selection_by_key: dict[tuple[float, ...], list[str]] = {}
    for name, candidate in selections.items():
        selection_by_key.setdefault(_coefficient_key(candidate), []).append(name)
    rows: list[dict[str, Any]] = []
    for candidate in search.candidates:
        coefficients = candidate.waveform.harmonic_coefficients
        rows.append(
            {
                "first_harmonic": coefficients[0],
                "second_harmonic": coefficients[1],
                "on_pareto_front": id(candidate) in front_ids,
                "representative": ";".join(
                    selection_by_key.get(_coefficient_key(candidate), [])
                ),
                "delay_variance_ratio_to_lfm": candidate.delay_variance_ratio,
                "delay_std_ratio_to_lfm": np.sqrt(
                    candidate.delay_variance_ratio
                ),
                "rms_bandwidth_hz": candidate.rms_bandwidth_hz,
                "mainlobe_width_samples": (
                    candidate.autocorrelation.mainlobe_width_samples
                ),
                "peak_sidelobe_db": candidate.autocorrelation.peak_sidelobe_db,
                "peak_sidelobe_amplitude_ratio_to_lfm": (
                    candidate.peak_sidelobe_amplitude_ratio
                ),
                "integrated_sidelobe_db": (
                    candidate.autocorrelation.integrated_sidelobe_db
                ),
                "integrated_sidelobe_energy_ratio_to_lfm": (
                    candidate.integrated_sidelobe_energy_ratio
                ),
                "doppler_coupling_samples_per_hz": abs(
                    candidate.doppler_coupling.slope_samples_per_hz
                ),
                "doppler_coupling_ratio_to_lfm": (
                    candidate.doppler_coupling_ratio
                ),
                "doppler_fit_residual_rms_samples": (
                    candidate.doppler_coupling.residual_rms_samples
                ),
            }
        )
    return rows


def _named_waveform(name: str, candidate: ParetoCandidate) -> FmWaveform:
    waveform = candidate.waveform
    return FmWaveform(
        name=name,
        samples=waveform.samples,
        instantaneous_frequency_hz=waveform.instantaneous_frequency_hz,
        harmonic_coefficients=waveform.harmonic_coefficients,
    )


def _paired_ambiguity_rows(
    waveforms: list[FmWaveform],
    config: FmWaveformConfig,
    dopplers_hz: list[float],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for waveform in waveforms:
        for doppler_hz in dopplers_hz:
            estimate = paired_ambiguity_estimate(
                waveform, config.sample_rate_hz, doppler_hz
            )
            rows.append(
                {
                    "waveform": waveform.name,
                    "harmonic_coefficients": ";".join(
                        f"{value:.12g}"
                        for value in waveform.harmonic_coefficients
                    ),
                    "doppler_hz": doppler_hz,
                    "up_delay_samples": estimate.up_delay_samples,
                    "down_delay_samples": estimate.down_delay_samples,
                    "paired_timing_delay_samples": estimate.timing_delay_samples,
                    "paired_timing_bias_m": (
                        SPEED_OF_LIGHT_M_S
                        * estimate.timing_delay_samples
                        / config.sample_rate_hz
                    ),
                    "doppler_displacement_samples": (
                        estimate.doppler_displacement_samples
                    ),
                    "mean_normalized_peak": estimate.mean_normalized_magnitude,
                }
            )
    return rows


def _paired_monte_carlo_rows(
    waveforms: list[FmWaveform],
    config: FmWaveformConfig,
    *,
    snr_db: float,
    trials: int,
    seed: int,
    mobile_doppler_hz: float,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for condition_index, doppler_hz in enumerate((0.0, mobile_doppler_hz)):
        condition_seed = seed + 100_000 + condition_index * 10_000
        for waveform in waveforms:
            result = monte_carlo_paired_toa(
                waveform,
                config,
                energy_snr_db=snr_db,
                trials=trials,
                rng=np.random.default_rng(condition_seed),
                doppler_hz=doppler_hz,
            )
            crlb_samples = (
                delay_crlb_std_s(waveform, snr_db) * config.sample_rate_hz
            )
            rows.append(
                {
                    "waveform": waveform.name,
                    "harmonic_coefficients": ";".join(
                        f"{value:.12g}"
                        for value in waveform.harmonic_coefficients
                    ),
                    "total_pair_energy": config.energy,
                    "energy_snr_db": snr_db,
                    "doppler_hz": doppler_hz,
                    "trials": trials,
                    "up_bias_samples": result.up_bias_samples,
                    "down_bias_samples": result.down_bias_samples,
                    "paired_bias_samples": result.bias_samples,
                    "paired_rmse_samples": result.rmse_samples,
                    "paired_rmse_m": (
                        SPEED_OF_LIGHT_M_S
                        * result.rmse_samples
                        / config.sample_rate_hz
                    ),
                    "total_energy_crlb_std_samples": crlb_samples,
                    "outlier_rate": result.outlier_rate,
                }
            )
    return rows


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise ValueError("cannot write an empty result table")
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def run_experiment(
    output: Path,
    *,
    trials: int,
    seed: int,
    snr_values_db: list[float],
) -> dict[str, Any]:
    # Capture provenance before creating output files, so a clean source tree
    # remains recorded as clean when the output directory is inside the repo.
    provenance = _git_provenance()
    config = FmWaveformConfig()
    carrier_hz = 868_000_000.0
    mobile_speed_m_s = 30.0
    mobile_doppler_hz = carrier_hz * mobile_speed_m_s / SPEED_OF_LIGHT_M_S
    crlb_snr_db = max(snr_values_db)

    lfm = make_lfm_waveform(config)
    nlfm = make_sinusoidal_nlfm_waveform(config)
    optimization = optimize_harmonic_fm(
        config, design_doppler_hz=mobile_doppler_hz
    )
    optimized = optimization.waveform
    waveforms = [lfm, nlfm, optimized]

    coupling_offsets_hz = [
        -2.0 * mobile_doppler_hz,
        -mobile_doppler_hz,
        mobile_doppler_hz,
        2.0 * mobile_doppler_hz,
    ]
    pareto_search = search_pareto_harmonic_fm(
        config, doppler_offsets_hz=coupling_offsets_hz
    )
    pareto_selections = _select_pareto_representatives(pareto_search)
    pareto = _pareto_rows(pareto_search, pareto_selections)
    pareto_front = [row for row in pareto if row["on_pareto_front"]]
    paired_waveforms = [
        _named_waveform(name, candidate)
        for name, candidate in pareto_selections.items()
    ]

    metrics = [
        _metric_row(
            waveform,
            config,
            crlb_snr_db=crlb_snr_db,
            mobile_doppler_hz=mobile_doppler_hz,
        )
        for waveform in waveforms
    ]
    ambiguity_grid = list(np.linspace(-500.0, 500.0, 41))
    ambiguity_grid.extend([-mobile_doppler_hz, mobile_doppler_hz])
    ambiguity_grid = sorted(set(float(value) for value in ambiguity_grid))
    ambiguity = _ambiguity_rows(waveforms, config, ambiguity_grid)
    monte_carlo = _monte_carlo_rows(
        waveforms,
        config,
        snr_values_db=snr_values_db,
        trials=trials,
        seed=seed,
        mobile_doppler_hz=mobile_doppler_hz,
    )
    paired_ambiguity = _paired_ambiguity_rows(
        paired_waveforms, config, ambiguity_grid
    )
    paired_monte_carlo = _paired_monte_carlo_rows(
        paired_waveforms,
        config,
        snr_db=crlb_snr_db,
        trials=trials,
        seed=seed,
        mobile_doppler_hz=mobile_doppler_hz,
    )

    output.mkdir(parents=True, exist_ok=True)
    _write_csv(output / "waveform-metrics.csv", metrics)
    _write_csv(output / "ambiguity-cuts.csv", ambiguity)
    _write_csv(output / "monte-carlo-toa.csv", monte_carlo)
    _write_csv(output / "pareto-candidates.csv", pareto)
    _write_csv(output / "pareto-front.csv", pareto_front)
    _write_csv(output / "paired-ambiguity.csv", paired_ambiguity)
    _write_csv(output / "paired-monte-carlo.csv", paired_monte_carlo)

    report: dict[str, Any] = {
        "schema_version": 1,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "generator": "tools/run_fm_positioning_experiment.py",
        "git": provenance,
        "configuration": {
            "sample_rate_hz": config.sample_rate_hz,
            "duration_s": config.duration_s,
            "sample_count": config.sample_count,
            "swept_bandwidth_hz": config.bandwidth_hz,
            "energy": config.energy,
            "carrier_hz": carrier_hz,
            "mobile_speed_m_s": mobile_speed_m_s,
            "mobile_doppler_hz": mobile_doppler_hz,
            "monte_carlo_trials_per_case": trials,
            "monte_carlo_seed": seed,
            "energy_snr_values_db": snr_values_db,
        },
        "optimization": {
            "family": "two-harmonic monotone endpoint-preserving FM",
            "objective": (
                "0.85 * delay-CRLB-std/LFM + "
                "0.15 * abs-Doppler-delay/LFM"
            ),
            "constraints": {
                "peak_sidelobe_db_max": -10.0,
                "integrated_sidelobe_db_max": -1.5,
                "minimum_normalized_slope": 0.02,
            },
            "design_doppler_hz": mobile_doppler_hz,
            "selected_harmonic_coefficients": list(
                optimized.harmonic_coefficients
            ),
            "relative_score": optimization.score,
            "feasible_candidates_evaluated": optimization.evaluated_candidates,
        },
        "pareto_search": {
            "objectives": [
                "delay_crlb_variance_ratio_to_lfm",
                "peak_sidelobe_amplitude_ratio_to_lfm",
                "integrated_sidelobe_energy_ratio_to_lfm",
                "absolute_delay_doppler_slope_ratio_to_lfm",
            ],
            "doppler_fit_offsets_hz": coupling_offsets_hz,
            "monotone_candidates": len(pareto_search.candidates),
            "pareto_front_size": len(pareto_search.front),
            "representatives": {
                name: next(
                    row
                    for row in pareto
                    if name in row["representative"].split(";")
                )
                for name in pareto_selections
            },
        },
        "paired_up_down": {
            "total_pair_energy": config.energy,
            "energy_per_chirp": config.energy / 2.0,
            "total_duration_s": 2.0 * config.duration_s,
            "timing_estimate": "half-sum of up/down matched-filter delays",
            "doppler_estimate": "half-difference of up/down matched-filter delays",
            "monte_carlo": paired_monte_carlo,
        },
        "metrics": metrics,
        "files": {
            "waveform_metrics": "waveform-metrics.csv",
            "ambiguity_cuts": "ambiguity-cuts.csv",
            "monte_carlo_toa": "monte-carlo-toa.csv",
            "pareto_candidates": "pareto-candidates.csv",
            "pareto_front": "pareto-front.csv",
            "paired_ambiguity": "paired-ambiguity.csv",
            "paired_monte_carlo": "paired-monte-carlo.csv",
        },
    }
    (output / "summary.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("artifacts/fm-positioning"),
        help="directory for JSON and CSV results",
    )
    parser.add_argument("--trials", type=int, default=2_000)
    parser.add_argument("--seed", type=int, default=20_260_921)
    parser.add_argument(
        "--snr-db",
        type=float,
        nargs="+",
        default=[0.0, 5.0, 10.0, 15.0, 20.0],
        help="Es/N0 values for the zero-Doppler Monte Carlo",
    )
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("--trials must be positive")
    if not args.snr_db or not all(np.isfinite(args.snr_db)):
        parser.error("--snr-db must contain finite values")

    report = run_experiment(
        args.output,
        trials=args.trials,
        seed=args.seed,
        snr_values_db=sorted(set(args.snr_db)),
    )
    print(f"Results: {args.output.resolve()}")
    print(
        "Optimized coefficients: "
        f"{report['optimization']['selected_harmonic_coefficients']}"
    )
    print(
        "Pareto front: "
        f"{report['pareto_search']['pareto_front_size']} / "
        f"{report['pareto_search']['monotone_candidates']} candidates"
    )
    for name, row in report["pareto_search"]["representatives"].items():
        print(
            f"{name:>18}: a=({row['first_harmonic']:.3f}, "
            f"{row['second_harmonic']:.3f}), "
            f"variance={row['delay_variance_ratio_to_lfm']:.3f}, "
            f"coupling={row['doppler_coupling_ratio_to_lfm']:.3f}"
        )
    for row in report["metrics"]:
        print(
            f"{row['waveform']:>16}: beta_rms={row['rms_bandwidth_hz'] / 1e3:7.3f} kHz, "
            f"PSL={row['peak_sidelobe_db']:7.3f} dB, "
            f"mobile bias={row['mobile_peak_bias_m']:8.3f} m"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
