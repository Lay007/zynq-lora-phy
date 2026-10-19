import importlib.util
import json
from pathlib import Path

import numpy as np
import pytest

from zynq_lora_phy.fm_positioning import (
    FmWaveformConfig,
    ambiguity_peak,
    autocorrelation_metrics,
    delay_crlb_std_s,
    make_lfm_waveform,
    make_sinusoidal_nlfm_waveform,
    monte_carlo_paired_toa,
    optimize_harmonic_fm,
    paired_ambiguity_estimate,
    rms_bandwidth_hz,
    search_pareto_harmonic_fm,
)


ROOT = Path(__file__).resolve().parents[1]
RUNNER_SPEC = importlib.util.spec_from_file_location(
    "run_fm_positioning_experiment",
    ROOT / "tools" / "run_fm_positioning_experiment.py",
)
assert RUNNER_SPEC is not None and RUNNER_SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER)


def test_equal_duration_bandwidth_and_energy_waveforms() -> None:
    config = FmWaveformConfig()
    lfm = make_lfm_waveform(config)
    nlfm = make_sinusoidal_nlfm_waveform(config)

    for waveform in (lfm, nlfm):
        assert waveform.samples.size == config.sample_count
        assert np.vdot(waveform.samples, waveform.samples).real == pytest.approx(
            config.energy, rel=1e-12
        )
        assert waveform.instantaneous_frequency_hz[0] == pytest.approx(
            -config.bandwidth_hz / 2.0
        )
        assert waveform.instantaneous_frequency_hz[-1] == pytest.approx(
            config.bandwidth_hz / 2.0
        )
        assert np.all(np.diff(waveform.instantaneous_frequency_hz) > 0.0)


def test_edge_dwelling_nlfm_increases_rms_bandwidth() -> None:
    config = FmWaveformConfig()
    lfm = make_lfm_waveform(config)
    nlfm = make_sinusoidal_nlfm_waveform(config)

    assert rms_bandwidth_hz(lfm) == pytest.approx(
        config.bandwidth_hz / np.sqrt(12.0), rel=2e-3
    )
    assert rms_bandwidth_hz(nlfm) > 1.2 * rms_bandwidth_hz(lfm)
    assert delay_crlb_std_s(nlfm, 20.0) < delay_crlb_std_s(lfm, 20.0)


def test_autocorrelation_and_ambiguity_metrics_are_resolved() -> None:
    config = FmWaveformConfig()
    waveform = make_lfm_waveform(config)
    metrics = autocorrelation_metrics(waveform, config.sample_rate_hz)
    negative = ambiguity_peak(waveform, config.sample_rate_hz, -100.0)
    positive = ambiguity_peak(waveform, config.sample_rate_hz, 100.0)

    assert 8 <= metrics.mainlobe_width_samples <= 24
    assert metrics.peak_sidelobe_db < -10.0
    assert metrics.integrated_sidelobe_db < 0.0
    assert negative.delay_samples == pytest.approx(-positive.delay_samples, abs=1e-9)
    assert negative.normalized_magnitude == pytest.approx(
        positive.normalized_magnitude, rel=1e-12
    )


def test_optimizer_is_deterministic_and_keeps_a_monotone_non_lfm_law() -> None:
    config = FmWaveformConfig(sample_rate_hz=250_000.0, duration_s=1.024e-3)
    search_first = np.array([0.0, 0.08, 0.16])
    search_second = np.array([-0.02, 0.0, 0.02])

    first = optimize_harmonic_fm(
        config,
        first_harmonics=search_first,
        second_harmonics=search_second,
        design_doppler_hz=100.0,
    )
    second = optimize_harmonic_fm(
        config,
        first_harmonics=search_first,
        second_harmonics=search_second,
        design_doppler_hz=100.0,
    )

    assert first.score < 1.0
    assert first.waveform.harmonic_coefficients != (0.0, 0.0)
    assert first.waveform.harmonic_coefficients == second.waveform.harmonic_coefficients
    assert first.score == pytest.approx(second.score, abs=1e-15)
    assert np.all(np.diff(first.waveform.instantaneous_frequency_hz) > 0.0)


def test_experiment_runner_writes_self_describing_tables(tmp_path: Path) -> None:
    report = RUNNER.run_experiment(
        tmp_path, trials=2, seed=17, snr_values_db=[20.0]
    )

    assert {row["waveform"] for row in report["metrics"]} == {
        "lfm",
        "sinusoidal_nlfm",
        "optimized_fm",
    }
    assert report["optimization"]["selected_harmonic_coefficients"] != [0.0, 0.0]
    assert (tmp_path / "waveform-metrics.csv").is_file()
    assert (tmp_path / "ambiguity-cuts.csv").is_file()
    assert (tmp_path / "monte-carlo-toa.csv").is_file()
    assert (tmp_path / "pareto-candidates.csv").is_file()
    assert (tmp_path / "pareto-front.csv").is_file()
    assert (tmp_path / "paired-ambiguity.csv").is_file()
    assert (tmp_path / "paired-monte-carlo.csv").is_file()
    persisted = json.loads((tmp_path / "summary.json").read_text(encoding="utf-8"))
    assert persisted["configuration"]["monte_carlo_seed"] == 17
    assert persisted["files"]["waveform_metrics"] == "waveform-metrics.csv"
    assert persisted["pareto_search"]["pareto_front_size"] > 1
    assert len(persisted["paired_up_down"]["monte_carlo"]) == 8


@pytest.mark.parametrize("coefficient", [0.0, 0.18, 0.28])
def test_up_down_pair_cancels_doppler_displacement(coefficient: float) -> None:
    config = FmWaveformConfig()
    waveform = make_sinusoidal_nlfm_waveform(config, coefficient=coefficient)

    estimate = paired_ambiguity_estimate(
        waveform, config.sample_rate_hz, doppler_hz=100.0
    )

    assert estimate.up_delay_samples == pytest.approx(
        -estimate.down_delay_samples, abs=1e-12
    )
    assert estimate.timing_delay_samples == pytest.approx(0.0, abs=1e-12)
    assert abs(estimate.doppler_displacement_samples) > 0.4


def test_pareto_search_returns_only_non_dominated_candidates() -> None:
    config = FmWaveformConfig(sample_rate_hz=250_000.0, duration_s=1.024e-3)
    result = search_pareto_harmonic_fm(
        config,
        first_harmonics=np.array([-0.04, 0.0, 0.08, 0.16]),
        second_harmonics=np.array([-0.02, 0.0, 0.02]),
        doppler_offsets_hz=(-100.0, 100.0),
    )

    assert 1 < len(result.front) < len(result.candidates)
    objectives = lambda candidate: np.array(
        [
            candidate.delay_variance_ratio,
            candidate.peak_sidelobe_amplitude_ratio,
            candidate.integrated_sidelobe_energy_ratio,
            candidate.doppler_coupling_ratio,
        ]
    )
    for candidate in result.front:
        target = objectives(candidate)
        assert not any(
            np.all(objectives(other) <= target)
            and np.any(objectives(other) < target)
            for other in result.candidates
        )


def test_paired_monte_carlo_removes_mobile_bias_at_fixed_total_energy() -> None:
    config = FmWaveformConfig()
    result = monte_carlo_paired_toa(
        make_lfm_waveform(config),
        config,
        energy_snr_db=30.0,
        trials=400,
        rng=np.random.default_rng(91),
        doppler_hz=100.0,
    )

    assert result.up_bias_samples < -0.5
    assert result.down_bias_samples > 0.5
    assert abs(result.bias_samples) < 0.03
    assert result.rmse_samples < 0.15
