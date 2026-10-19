"""FM waveform primitives and positioning-oriented quality metrics.

The functions in this module deliberately stay independent of the packet and
RTL models.  They use the same complex-baseband, NumPy-array conventions as the
CSS reference model, which makes the experiment useful without implying that a
new waveform is already compatible with the LoRa modem implementation.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product

import numpy as np
from numpy.typing import ArrayLike, NDArray

from .toa import estimate_toa


ComplexArray = NDArray[np.complex128]
FloatArray = NDArray[np.float64]
SPEED_OF_LIGHT_M_S = 299_792_458.0


@dataclass(frozen=True)
class FmWaveformConfig:
    """Shared duration, swept bandwidth, sample rate, and energy definition."""

    sample_rate_hz: float = 1_000_000.0
    duration_s: float = 1.024e-3
    bandwidth_hz: float = 125_000.0
    energy: float = 1.0

    def __post_init__(self) -> None:
        if not np.isfinite(self.sample_rate_hz) or self.sample_rate_hz <= 0.0:
            raise ValueError("sample_rate_hz must be finite and positive")
        if not np.isfinite(self.duration_s) or self.duration_s <= 0.0:
            raise ValueError("duration_s must be finite and positive")
        if not np.isfinite(self.bandwidth_hz) or self.bandwidth_hz <= 0.0:
            raise ValueError("bandwidth_hz must be finite and positive")
        if self.bandwidth_hz >= self.sample_rate_hz:
            raise ValueError("bandwidth_hz must be below the sample rate")
        if not np.isfinite(self.energy) or self.energy <= 0.0:
            raise ValueError("energy must be finite and positive")
        exact_count = self.sample_rate_hz * self.duration_s
        if not np.isclose(exact_count, round(exact_count), atol=1e-9, rtol=0.0):
            raise ValueError("sample_rate_hz * duration_s must be an integer")
        if round(exact_count) < 16:
            raise ValueError("the waveform must contain at least 16 samples")

    @property
    def sample_count(self) -> int:
        return int(round(self.sample_rate_hz * self.duration_s))


@dataclass(frozen=True)
class FmWaveform:
    """One finite FM waveform and the instantaneous-frequency law that made it."""

    name: str
    samples: ComplexArray
    instantaneous_frequency_hz: FloatArray
    harmonic_coefficients: tuple[float, ...]


@dataclass(frozen=True)
class AutocorrelationMetrics:
    """Aperiodic matched-filter metrics normalized to the zero-lag peak."""

    mainlobe_width_samples: int
    mainlobe_width_s: float
    peak_sidelobe_db: float
    integrated_sidelobe_db: float


@dataclass(frozen=True)
class AmbiguityPeak:
    """Peak of one delay cut through the delay-Doppler ambiguity function."""

    doppler_hz: float
    delay_samples: float
    normalized_magnitude: float


@dataclass(frozen=True)
class ToaMonteCarloResult:
    """Summary of repeated matched-filter ToA estimates."""

    snr_db: float
    doppler_hz: float
    trials: int
    bias_samples: float
    rmse_samples: float
    outlier_rate: float


@dataclass(frozen=True)
class OptimizationResult:
    """Selected harmonic law and its score relative to the LFM baseline."""

    waveform: FmWaveform
    score: float
    evaluated_candidates: int


@dataclass(frozen=True)
class DopplerCouplingMetrics:
    """Linearized displacement of the ambiguity peak with Doppler."""

    slope_samples_per_hz: float
    intercept_samples: float
    residual_rms_samples: float


@dataclass(frozen=True)
class PairedAmbiguityEstimate:
    """Timing and Doppler displacement from conjugate up/down FM pulses."""

    doppler_hz: float
    up_delay_samples: float
    down_delay_samples: float
    timing_delay_samples: float
    doppler_displacement_samples: float
    mean_normalized_magnitude: float


@dataclass(frozen=True)
class PairedToaMonteCarloResult:
    """Monte Carlo result for a half-sum up/down timing estimate."""

    snr_db: float
    doppler_hz: float
    trials: int
    up_bias_samples: float
    down_bias_samples: float
    bias_samples: float
    rmse_samples: float
    outlier_rate: float


@dataclass(frozen=True)
class ParetoCandidate:
    """One harmonic FM law and its LFM-normalized minimization objectives."""

    waveform: FmWaveform
    delay_variance_ratio: float
    peak_sidelobe_amplitude_ratio: float
    integrated_sidelobe_energy_ratio: float
    doppler_coupling_ratio: float
    rms_bandwidth_hz: float
    autocorrelation: AutocorrelationMetrics
    doppler_coupling: DopplerCouplingMetrics


@dataclass(frozen=True)
class ParetoSearchResult:
    """All monotone candidates and the non-dominated subset."""

    candidates: tuple[ParetoCandidate, ...]
    front: tuple[ParetoCandidate, ...]


def harmonic_frequency_law(
    config: FmWaveformConfig,
    coefficients: tuple[float, ...] = (),
    *,
    minimum_normalized_slope: float = 0.02,
) -> FloatArray:
    """Return a monotone endpoint-preserving FM law.

    With normalized time ``x`` in ``[-1, 1]`` the law is

    ``f(x) = B/2 * (x + sum(a_k sin(k*pi*x)))``.

    Empty coefficients give classic LFM.  Harmonic terms reshape how long the
    signal dwells in each part of the same ``[-B/2, B/2]`` sweep.  Requiring a
    positive derivative keeps the law monotone and avoids hidden frequency
    reversals in the optimized candidate set.
    """

    x = np.linspace(-1.0, 1.0, config.sample_count, dtype=np.float64)
    normalized = x.copy()
    derivative = np.ones_like(x)
    for index, coefficient in enumerate(coefficients, start=1):
        if not np.isfinite(coefficient):
            raise ValueError("harmonic coefficients must be finite")
        normalized += coefficient * np.sin(index * np.pi * x)
        derivative += coefficient * index * np.pi * np.cos(index * np.pi * x)
    if float(np.min(derivative)) < minimum_normalized_slope:
        raise ValueError("harmonic coefficients do not define a monotone sweep")
    return 0.5 * config.bandwidth_hz * normalized


def make_fm_waveform(
    name: str,
    config: FmWaveformConfig,
    coefficients: tuple[float, ...] = (),
) -> FmWaveform:
    """Generate a unit-convention complex FM waveform from a harmonic law."""

    frequency = harmonic_frequency_law(config, coefficients)
    phase_cycles = np.zeros(config.sample_count, dtype=np.float64)
    phase_cycles[1:] = np.cumsum(
        0.5 * (frequency[:-1] + frequency[1:]) / config.sample_rate_hz
    )
    samples = np.exp(2j * np.pi * phase_cycles)
    samples *= np.sqrt(config.energy / float(np.vdot(samples, samples).real))
    return FmWaveform(
        name=name,
        samples=samples.astype(np.complex128, copy=False),
        instantaneous_frequency_hz=frequency,
        harmonic_coefficients=tuple(float(value) for value in coefficients),
    )


def make_lfm_waveform(config: FmWaveformConfig) -> FmWaveform:
    """Generate the classic linear sweep baseline."""

    return make_fm_waveform("lfm", config)


def make_sinusoidal_nlfm_waveform(
    config: FmWaveformConfig, *, coefficient: float = 0.28
) -> FmWaveform:
    """Generate an edge-dwelling sinusoidal NLFM comparison waveform."""

    return make_fm_waveform("sinusoidal_nlfm", config, (coefficient, 0.0))


def rms_bandwidth_hz(waveform: FmWaveform) -> float:
    """Return the energy-weighted RMS bandwidth of the interior FM law.

    This is the central second moment of instantaneous frequency.  It excludes
    the common ideal rectangular pulse-gating edge, whose unlimited bandwidth
    would otherwise obscure the comparison between phase laws.
    """

    power = np.abs(waveform.samples) ** 2
    total = float(np.sum(power))
    mean = float(np.sum(power * waveform.instantaneous_frequency_hz) / total)
    variance = float(
        np.sum(power * (waveform.instantaneous_frequency_hz - mean) ** 2) / total
    )
    return float(np.sqrt(max(variance, 0.0)))


def delay_crlb_std_s(waveform: FmWaveform, energy_snr_db: float) -> float:
    """Known-waveform delay CRLB standard deviation for complex AWGN.

    ``energy_snr_db`` is ``Es/N0``.  Unknown constant carrier phase is treated
    as a nuisance parameter, hence the central (RMS) rather than raw second
    frequency moment.
    """

    if not np.isfinite(energy_snr_db):
        raise ValueError("energy_snr_db must be finite")
    beta = rms_bandwidth_hz(waveform)
    snr = 10.0 ** (energy_snr_db / 10.0)
    return float(1.0 / np.sqrt(8.0 * np.pi**2 * snr * beta**2))


def _fft_correlation(first: ComplexArray, second: ComplexArray) -> ComplexArray:
    """Return the full aperiodic correlation using a zero-padded FFT."""

    output_size = first.size + second.size - 1
    fft_size = 1 << (output_size - 1).bit_length()
    spectrum = np.fft.fft(first, fft_size) * np.fft.fft(
        np.conjugate(second[::-1]), fft_size
    )
    return np.fft.ifft(spectrum)[:output_size]


def _first_local_minimum(values: FloatArray, start: int, direction: int) -> int:
    index = start + direction
    while 0 < index < values.size - 1:
        if values[index] <= values[index - 1] and values[index] <= values[index + 1]:
            return index
        index += direction
    raise ValueError("autocorrelation has no resolvable mainlobe boundary")


def autocorrelation_metrics(
    waveform: FmWaveform, sample_rate_hz: float
) -> AutocorrelationMetrics:
    """Measure null-to-null mainlobe width, PSL, and ISL."""

    correlation = _fft_correlation(waveform.samples, waveform.samples)
    magnitude = np.abs(correlation)
    center = waveform.samples.size - 1
    magnitude /= magnitude[center]
    left = _first_local_minimum(magnitude, center, -1)
    right = _first_local_minimum(magnitude, center, 1)
    mainlobe = np.zeros(magnitude.size, dtype=bool)
    mainlobe[left : right + 1] = True
    sidelobe_peak = float(np.max(magnitude[~mainlobe]))
    sidelobe_energy = float(np.sum(magnitude[~mainlobe] ** 2))
    mainlobe_energy = float(np.sum(magnitude[mainlobe] ** 2))
    return AutocorrelationMetrics(
        mainlobe_width_samples=right - left,
        mainlobe_width_s=(right - left) / sample_rate_hz,
        peak_sidelobe_db=float(
            20.0 * np.log10(max(sidelobe_peak, np.finfo(float).tiny))
        ),
        integrated_sidelobe_db=float(
            10.0
            * np.log10(
                max(sidelobe_energy / mainlobe_energy, np.finfo(float).tiny)
            )
        ),
    )


def ambiguity_peak(
    waveform: FmWaveform, sample_rate_hz: float, doppler_hz: float
) -> AmbiguityPeak:
    """Find the fractional-delay peak of an aperiodic ambiguity cut."""

    sample_indices = np.arange(waveform.samples.size, dtype=np.float64)
    shifted = waveform.samples * np.exp(
        2j * np.pi * doppler_hz * sample_indices / sample_rate_hz
    )
    correlation = _fft_correlation(shifted, waveform.samples)
    metric = np.abs(correlation) ** 2
    peak = int(np.argmax(metric))
    fractional = 0.0
    if 0 < peak < metric.size - 1:
        left, center, right = metric[peak - 1 : peak + 2]
        denominator = left - 2.0 * center + right
        if denominator != 0.0:
            fractional = float(np.clip(0.5 * (left - right) / denominator, -0.5, 0.5))
    delay = peak + fractional - (waveform.samples.size - 1)
    peak_magnitude = float(np.sqrt(metric[peak]))
    energy = float(np.vdot(waveform.samples, waveform.samples).real)
    return AmbiguityPeak(
        doppler_hz=float(doppler_hz),
        delay_samples=float(delay),
        normalized_magnitude=peak_magnitude / energy,
    )


def delay_doppler_coupling(
    waveform: FmWaveform,
    sample_rate_hz: float,
    doppler_offsets_hz: ArrayLike,
) -> DopplerCouplingMetrics:
    """Fit ambiguity-peak delay against Doppler over a symmetric local grid."""

    offsets = np.asarray(doppler_offsets_hz, dtype=np.float64)
    if offsets.ndim != 1 or offsets.size < 2:
        raise ValueError("doppler_offsets_hz must contain at least two values")
    if not np.all(np.isfinite(offsets)) or np.all(offsets == offsets[0]):
        raise ValueError("doppler offsets must be finite and not all equal")
    delays = np.asarray(
        [
            ambiguity_peak(waveform, sample_rate_hz, float(offset)).delay_samples
            for offset in offsets
        ],
        dtype=np.float64,
    )
    centered = offsets - float(np.mean(offsets))
    slope = float(np.dot(centered, delays) / np.dot(centered, centered))
    intercept = float(np.mean(delays) - slope * np.mean(offsets))
    residual = delays - (intercept + slope * offsets)
    return DopplerCouplingMetrics(
        slope_samples_per_hz=slope,
        intercept_samples=intercept,
        residual_rms_samples=float(np.sqrt(np.mean(residual**2))),
    )


def make_downchirp(waveform: FmWaveform) -> FmWaveform:
    """Return the conjugate down-sweep paired with an odd-symmetric up-sweep."""

    return FmWaveform(
        name=f"{waveform.name}_down",
        samples=np.conjugate(waveform.samples),
        instantaneous_frequency_hz=-waveform.instantaneous_frequency_hz,
        harmonic_coefficients=waveform.harmonic_coefficients,
    )


def paired_ambiguity_estimate(
    up_waveform: FmWaveform,
    sample_rate_hz: float,
    doppler_hz: float,
) -> PairedAmbiguityEstimate:
    """Average conjugate up/down ambiguity peaks to cancel first-order Doppler."""

    up = ambiguity_peak(up_waveform, sample_rate_hz, doppler_hz)
    down = ambiguity_peak(
        make_downchirp(up_waveform), sample_rate_hz, doppler_hz
    )
    return PairedAmbiguityEstimate(
        doppler_hz=float(doppler_hz),
        up_delay_samples=up.delay_samples,
        down_delay_samples=down.delay_samples,
        timing_delay_samples=0.5 * (up.delay_samples + down.delay_samples),
        doppler_displacement_samples=0.5 * (up.delay_samples - down.delay_samples),
        mean_normalized_magnitude=0.5
        * (up.normalized_magnitude + down.normalized_magnitude),
    )


def _is_pareto_efficient(objectives: FloatArray) -> NDArray[np.bool_]:
    efficient = np.ones(objectives.shape[0], dtype=bool)
    for index, objective in enumerate(objectives):
        no_worse = np.all(objectives <= objective, axis=1)
        strictly_better = np.any(objectives < objective, axis=1)
        if np.any(no_worse & strictly_better):
            efficient[index] = False
    return efficient


def search_pareto_harmonic_fm(
    config: FmWaveformConfig,
    *,
    first_harmonics: ArrayLike | None = None,
    second_harmonics: ArrayLike | None = None,
    doppler_offsets_hz: ArrayLike = (-200.0, -100.0, 100.0, 200.0),
) -> ParetoSearchResult:
    """Find the four-objective Pareto front in the two-harmonic FM family.

    Delay CRLB variance, PSL amplitude, ISL energy, and the absolute local
    delay-Doppler slope are minimized independently.  Every value is divided
    by the LFM value before dominance is tested, so LFM is ``(1, 1, 1, 1)``.
    PSL and ISL remain separate objectives because merging them into one scalar
    can hide a waveform with a good peak but excessive total sidelobe energy.
    """

    first = (
        np.linspace(-0.08, 0.30, 39)
        if first_harmonics is None
        else np.asarray(first_harmonics, dtype=np.float64)
    )
    second = (
        np.linspace(-0.08, 0.08, 17)
        if second_harmonics is None
        else np.asarray(second_harmonics, dtype=np.float64)
    )
    baseline = make_lfm_waveform(config)
    baseline_beta = rms_bandwidth_hz(baseline)
    baseline_ac = autocorrelation_metrics(baseline, config.sample_rate_hz)
    baseline_coupling = delay_doppler_coupling(
        baseline, config.sample_rate_hz, doppler_offsets_hz
    )
    baseline_slope = abs(baseline_coupling.slope_samples_per_hz)
    candidates: list[ParetoCandidate] = []
    for first_value, second_value in product(first, second):
        try:
            waveform = make_fm_waveform(
                "pareto_fm", config, (float(first_value), float(second_value))
            )
        except ValueError:
            continue
        beta = rms_bandwidth_hz(waveform)
        correlation = autocorrelation_metrics(waveform, config.sample_rate_hz)
        coupling = delay_doppler_coupling(
            waveform, config.sample_rate_hz, doppler_offsets_hz
        )
        candidates.append(
            ParetoCandidate(
                waveform=waveform,
                delay_variance_ratio=float((baseline_beta / beta) ** 2),
                peak_sidelobe_amplitude_ratio=float(
                    10.0
                    ** (
                        (correlation.peak_sidelobe_db - baseline_ac.peak_sidelobe_db)
                        / 20.0
                    )
                ),
                integrated_sidelobe_energy_ratio=float(
                    10.0
                    ** (
                        (
                            correlation.integrated_sidelobe_db
                            - baseline_ac.integrated_sidelobe_db
                        )
                        / 10.0
                    )
                ),
                doppler_coupling_ratio=float(
                    abs(coupling.slope_samples_per_hz) / baseline_slope
                ),
                rms_bandwidth_hz=beta,
                autocorrelation=correlation,
                doppler_coupling=coupling,
            )
        )
    objectives = np.asarray(
        [
            (
                candidate.delay_variance_ratio,
                candidate.peak_sidelobe_amplitude_ratio,
                candidate.integrated_sidelobe_energy_ratio,
                candidate.doppler_coupling_ratio,
            )
            for candidate in candidates
        ],
        dtype=np.float64,
    )
    efficient = _is_pareto_efficient(objectives)
    front = tuple(
        candidate
        for candidate, keep in zip(candidates, efficient, strict=True)
        if keep
    )
    return ParetoSearchResult(candidates=tuple(candidates), front=front)


def _relative_optimization_score(
    waveform: FmWaveform,
    baseline: FmWaveform,
    config: FmWaveformConfig,
    design_doppler_hz: float,
) -> float:
    candidate_doppler = np.mean(
        [
            abs(ambiguity_peak(waveform, config.sample_rate_hz, sign * design_doppler_hz).delay_samples)
            for sign in (-1.0, 1.0)
        ]
    )
    baseline_doppler = np.mean(
        [
            abs(ambiguity_peak(baseline, config.sample_rate_hz, sign * design_doppler_hz).delay_samples)
            for sign in (-1.0, 1.0)
        ]
    )
    crlb_ratio = rms_bandwidth_hz(baseline) / rms_bandwidth_hz(waveform)
    doppler_ratio = candidate_doppler / max(baseline_doppler, np.finfo(float).eps)
    return float(0.85 * crlb_ratio + 0.15 * doppler_ratio)


def optimize_harmonic_fm(
    config: FmWaveformConfig,
    *,
    first_harmonics: ArrayLike | None = None,
    second_harmonics: ArrayLike | None = None,
    design_doppler_hz: float = 100.0,
    maximum_peak_sidelobe_db: float = -10.0,
    maximum_integrated_sidelobe_db: float = -1.5,
) -> OptimizationResult:
    """Grid-search a deterministic two-harmonic law for positioning metrics.

    The scalar objective uses relative quantities so it remains dimensionless:
    85% delay-CRLB standard deviation and 15% absolute ambiguity-peak
    displacement at ``±design_doppler_hz``.  Candidates must also satisfy the
    supplied PSL and ISL ceilings.  LFM therefore has score 1.0.  This is an
    exploratory constrained search, not a claim of global optimality over all
    possible FM laws.
    """

    if not np.isfinite(design_doppler_hz) or design_doppler_hz <= 0.0:
        raise ValueError("design_doppler_hz must be finite and positive")
    first = (
        np.linspace(-0.04, 0.30, 18)
        if first_harmonics is None
        else np.asarray(first_harmonics, dtype=np.float64)
    )
    second = (
        np.linspace(-0.06, 0.06, 13)
        if second_harmonics is None
        else np.asarray(second_harmonics, dtype=np.float64)
    )
    baseline = make_lfm_waveform(config)
    best_waveform = baseline
    best_score = 1.0
    evaluated = 0
    for first_value, second_value in product(first, second):
        coefficients = (float(first_value), float(second_value))
        try:
            candidate = make_fm_waveform("optimized_fm", config, coefficients)
        except ValueError:
            continue
        candidate_ac = autocorrelation_metrics(candidate, config.sample_rate_hz)
        if candidate_ac.peak_sidelobe_db > maximum_peak_sidelobe_db:
            continue
        if candidate_ac.integrated_sidelobe_db > maximum_integrated_sidelobe_db:
            continue
        score = _relative_optimization_score(
            candidate, baseline, config, design_doppler_hz
        )
        evaluated += 1
        if score < best_score:
            best_waveform = candidate
            best_score = score
    return OptimizationResult(
        waveform=best_waveform,
        score=float(best_score),
        evaluated_candidates=evaluated,
    )


def monte_carlo_toa(
    waveform: FmWaveform,
    config: FmWaveformConfig,
    *,
    energy_snr_db: float,
    trials: int,
    rng: np.random.Generator,
    doppler_hz: float = 0.0,
    true_delay_samples: int = 32,
    guard_samples: int = 32,
) -> ToaMonteCarloResult:
    """Run grid-aligned ToA estimation in complex AWGN and optional Doppler."""

    if trials < 1:
        raise ValueError("trials must be positive")
    if true_delay_samples < 0 or guard_samples < 1:
        raise ValueError("delays and guards must be non-negative with a positive guard")
    if true_delay_samples > 2 * guard_samples:
        raise ValueError("true_delay_samples must lie inside the search guard")
    received_size = waveform.samples.size + 2 * guard_samples
    clean = np.zeros(received_size, dtype=np.complex128)
    clean[
        true_delay_samples : true_delay_samples + waveform.samples.size
    ] = waveform.samples
    indices = np.arange(received_size, dtype=np.float64)
    clean *= np.exp(2j * np.pi * doppler_hz * indices / config.sample_rate_hz)
    noise_power = config.energy / (10.0 ** (energy_snr_db / 10.0))
    noise_scale = np.sqrt(noise_power / 2.0)
    errors = np.empty(trials, dtype=np.float64)
    for trial in range(trials):
        noise = noise_scale * (
            rng.standard_normal(received_size) + 1j * rng.standard_normal(received_size)
        )
        estimate = estimate_toa(clean + noise, waveform.samples)
        errors[trial] = estimate.sample_index - true_delay_samples
    return ToaMonteCarloResult(
        snr_db=float(energy_snr_db),
        doppler_hz=float(doppler_hz),
        trials=int(trials),
        bias_samples=float(np.mean(errors)),
        rmse_samples=float(np.sqrt(np.mean(errors**2))),
        outlier_rate=float(np.mean(np.abs(errors) > 1.0)),
    )


def monte_carlo_paired_toa(
    waveform: FmWaveform,
    config: FmWaveformConfig,
    *,
    energy_snr_db: float,
    trials: int,
    rng: np.random.Generator,
    doppler_hz: float = 0.0,
    true_delay_samples: int = 32,
    guard_samples: int = 32,
) -> PairedToaMonteCarloResult:
    """Estimate timing from an up/down pair with fixed total pair energy.

    Half of ``config.energy`` is assigned to each chirp.  The two matched-filter
    estimates therefore use independent noise at 3 dB lower per-chirp Es/N0,
    and their half-sum has the same ideal delay information as one full-energy
    chirp while cancelling equal-and-opposite Doppler displacement.
    """

    if not np.isfinite(energy_snr_db) or not np.isfinite(doppler_hz):
        raise ValueError("SNR and Doppler must be finite")
    if trials < 1:
        raise ValueError("trials must be positive")
    if true_delay_samples < 0 or guard_samples < 1:
        raise ValueError("delays and guards must be non-negative with a positive guard")
    if true_delay_samples > 2 * guard_samples:
        raise ValueError("true_delay_samples must lie inside the search guard")

    input_energy = float(np.vdot(waveform.samples, waveform.samples).real)
    scale = np.sqrt(config.energy / (2.0 * input_energy))
    up_reference = waveform.samples * scale
    down_reference = np.conjugate(waveform.samples) * scale
    received_size = waveform.samples.size + 2 * guard_samples
    up_clean = np.zeros(received_size, dtype=np.complex128)
    down_clean = np.zeros(received_size, dtype=np.complex128)
    signal_slice = slice(
        true_delay_samples, true_delay_samples + waveform.samples.size
    )
    up_clean[signal_slice] = up_reference
    down_clean[signal_slice] = down_reference
    local_indices = np.arange(received_size, dtype=np.float64)
    up_clean *= np.exp(
        2j * np.pi * doppler_hz * local_indices / config.sample_rate_hz
    )
    down_global_indices = local_indices + received_size
    down_clean *= np.exp(
        2j * np.pi * doppler_hz * down_global_indices / config.sample_rate_hz
    )

    noise_power = config.energy / (10.0 ** (energy_snr_db / 10.0))
    noise_scale = np.sqrt(noise_power / 2.0)
    up_errors = np.empty(trials, dtype=np.float64)
    down_errors = np.empty(trials, dtype=np.float64)
    for trial in range(trials):
        up_noise = noise_scale * (
            rng.standard_normal(received_size) + 1j * rng.standard_normal(received_size)
        )
        down_noise = noise_scale * (
            rng.standard_normal(received_size) + 1j * rng.standard_normal(received_size)
        )
        up_estimate = estimate_toa(up_clean + up_noise, up_reference)
        down_estimate = estimate_toa(down_clean + down_noise, down_reference)
        up_errors[trial] = up_estimate.sample_index - true_delay_samples
        down_errors[trial] = down_estimate.sample_index - true_delay_samples
    timing_errors = 0.5 * (up_errors + down_errors)
    return PairedToaMonteCarloResult(
        snr_db=float(energy_snr_db),
        doppler_hz=float(doppler_hz),
        trials=int(trials),
        up_bias_samples=float(np.mean(up_errors)),
        down_bias_samples=float(np.mean(down_errors)),
        bias_samples=float(np.mean(timing_errors)),
        rmse_samples=float(np.sqrt(np.mean(timing_errors**2))),
        outlier_rate=float(np.mean(np.abs(timing_errors) > 1.0)),
    )
