# FM waveform shape for positioning

This model-level experiment asks whether changing the frequency law of a chirp
can improve delay estimation while duration, swept bandwidth, and energy stay
fixed. It compares classic LFM, a deliberately aggressive sinusoidal NLFM, and
a constrained, numerically selected FM law.

This is floating-point evidence only. It does not establish LoRa packet
compatibility, FPGA cost, spectral-mask compliance, RF performance, or
board-level positioning accuracy.

## Reproduce the run

From an environment with the package and development dependencies installed:

```powershell
python tools/run_fm_positioning_experiment.py `
  --output docs/data/fm-positioning `
  --trials 2000 `
  --seed 20260921 `
  --snr-db 0 5 10 15 20
```

The committed report was generated from clean commit `89007bb` on branch
`experiment/fm-positioning-waveforms`. The full hash and clean/dirty state are
recorded in [`summary.json`](data/fm-positioning/summary.json).

## Equal-resource definition

Every signal uses:

- 1 MS/s complex-baseband sampling;
- 1024 samples, or 1.024 ms;
- the same monotone sweep from -62.5 to +62.5 kHz (125 kHz total);
- energy normalized to one.

For normalized time `x` in `[-1, 1]`, the search family is

```text
f(x) = B/2 * (x + a1*sin(pi*x) + a2*sin(2*pi*x)).
```

LFM is `(a1, a2) = (0, 0)`. The fixed sinusoidal NLFM uses `(0.28, 0)` and
dwells near the band edges, increasing the frequency second moment. The
optimized law was selected from `a1=-0.04:0.02:0.30` and
`a2=-0.06:0.01:0.06`, subject to a positive normalized slope of at least 0.02,
PSL no worse than -10 dB, and ISL no worse than -1.5 dB. Among the 92 feasible
candidates, the objective was

```text
0.85 * (delay CRLB standard deviation / LFM)
+ 0.15 * (absolute Doppler delay displacement / LFM).
```

The selected coefficients are `(0.18, -0.06)`. This is a deterministic
two-parameter grid result, not a global optimum over arbitrary FM signals.

RMS bandwidth is the energy-weighted central second moment of the interior
instantaneous-frequency law. The identical ideal rectangular gate is excluded:
its discontinuity would otherwise give an unbounded continuous-time spectral
second moment and obscure the phase-law comparison.

## Deterministic metrics

The CRLB column uses `Es/N0 = 20 dB`. Mainlobe width is measured between the
first autocorrelation minima. Range values use one-way propagation.

| waveform | RMS bandwidth, kHz | delay CRLB, ns | CRLB range, m | mainlobe, us | PSL, dB | ISL, dB | delay at +86.86 Hz, samples |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| LFM | 36.120 | 311.6 | 93.4 | 16 | -13.48 | -9.76 | -0.697 |
| sinusoidal NLFM | 46.403 | 242.5 | 72.7 | 12 | -6.68 | +0.74 | -0.536 |
| optimized FM | 43.550 | 258.4 | 77.5 | 12 | -10.04 | -1.79 | -0.577 |

Relative to LFM, the fixed NLFM increases RMS bandwidth by 28.5% and lowers
the delay-CRLB standard deviation by 22.2%. The optimized law gains 20.6% RMS
bandwidth and lowers the bound by 17.1%. Both narrow the sampled null-to-null
mainlobe by 25%.

The cost is visible in the sidelobes. The fixed NLFM loses 6.80 dB of PSL and
10.49 dB of ISL; its total sidelobe energy exceeds its mainlobe energy. The
constrained law limits the PSL to -10.04 dB but still loses 3.45 dB of PSL and
7.97 dB of ISL relative to LFM. It is therefore the more credible compromise
for acquisition, not the waveform with the lowest theoretical delay variance.

## AWGN and mobile results

The Monte Carlo uses the existing parabolic matched-filter ToA estimator. Each
waveform gets its matched template, the same Gaussian draws for each condition,
and 2000 trials. SNR means `Es/N0`; the injected delay is grid-aligned. An
outlier is an error greater than one sample.

| case | LFM RMSE, samples | sinusoidal NLFM | optimized FM |
| --- | ---: | ---: | ---: |
| 15 dB, no Doppler | 0.564 | 0.436 | 0.513 |
| 20 dB, no Doppler | 0.316 | 0.235 | 0.248 |
| 20 dB, +86.86 Hz | 0.762 | 0.594 | 0.637 |

At 20 dB without Doppler, the fixed and optimized laws reduce RMSE by 25.6%
and 21.7%, respectively. Near 15--20 dB the results follow the CRLB ordering.
At 10 dB and below threshold errors dominate: lower CRLB alone does not produce
lower total RMSE, so the result must not be extrapolated into the acquisition
threshold region.

The mobile case uses 30 m/s at an 868 MHz carrier, giving 86.86 Hz Doppler. With
no Doppler compensation the deterministic ambiguity-peak displacement maps to
one-way biases of -208.9 m for LFM, -160.7 m for fixed NLFM, and -173.0 m for
optimized FM. Including noise, the two nonlinear laws reduce 20 dB RMSE by
22.0% and 16.4%. The remaining bias is large: waveform shaping helps but does
not replace CFO/Doppler estimation or an up/down-chirp cancellation scheme.

## Pareto search

The follow-up search evaluates every monotone member of the two-harmonic grid
without the earlier PSL/ISL constraints. Four quantities are minimized without
scalarization:

1. delay-CRLB variance relative to LFM;
2. PSL amplitude relative to LFM;
3. ISL energy relative to LFM;
4. absolute delay-Doppler slope relative to LFM, fitted at
   `±86.86` and `±173.72 Hz`.

Keeping PSL and ISL separate prevents a low isolated peak from hiding excessive
total sidelobe energy. Of 599 monotone laws, 212 lie on the strict four-objective
Pareto front. Representative points are:

| point | `(a1, a2)` | delay variance / LFM | delay std / LFM | PSL, dB | ISL, dB | coupling / LFM |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| sidelobe focused | `(-0.08, 0.01)` | 1.179 | 1.086 | -18.92 | -14.05 | 1.085 |
| LFM | `(0, 0)` | 1.000 | 1.000 | -13.48 | -9.76 | 1.000 |
| normalized knee | `(0.10, -0.05)` | 0.796 | 0.892 | -11.70 | -4.64 | 0.890 |
| constrained point from the first search | `(0.18, -0.06)` | 0.688 | 0.829 | -10.04 | -1.79 | 0.826 |
| delay focused | `(0.30, 0)` | 0.586 | 0.766 | -6.41 | +1.38 | 0.755 |

LFM itself remains non-dominated. There is therefore no law in this family
that simultaneously improves delay variance, both sidelobe measures, and
delay-Doppler coupling. Moving toward the delay-focused edge reduces variance
by 41.4% and coupling by 24.5%, but makes the sidelobes unsuitable for robust
acquisition. Moving in the opposite direction improves PSL by 5.43 dB and ISL
by 4.29 dB while worsening variance by 17.9% and coupling by 8.5%.

The normalized knee is the shortest Euclidean distance to the component-wise
utopia point after log-domain min-max normalization. It is a reproducible
mathematical representative, not a universal engineering preference. The
earlier constrained point remains a useful choice when a -10 dB PSL floor is
acceptable.

## Paired up/down test

The paired receiver matches an up-sweep and its complex-conjugate down-sweep,
then forms

```text
timing = (delay_up + delay_down) / 2
Doppler displacement = (delay_up - delay_down) / 2.
```

Total pair energy remains one: each chirp receives energy 0.5. The pair lasts
2.048 ms, twice the single-chirp duration. This prevents an apparent gain from
silently doubling transmit energy, but the latency/airtime cost remains.

For all four representative laws, the deterministic paired timing residual is
below `5.7e-14` sample over `-500...+500 Hz`. This exact numerical cancellation
is a consequence of the ideal conjugate waveform and channel symmetry.

At `Es/N0 = 20 dB`, 2000 Monte Carlo trials give:

| pair | RMSE at 0 Hz, samples | bias at +86.86 Hz, samples | RMSE at +86.86 Hz, samples |
| --- | ---: | ---: | ---: |
| LFM | 0.312 | -0.005 | 0.318 |
| normalized knee | 0.271 | +0.005 | 0.281 |
| delay focused | 0.239 | +0.004 | 0.234 |
| sidelobe focused | 0.337 | -0.005 | 0.337 |

For LFM, pairing reduces the mobile RMSE from 0.762 to 0.318 sample, or 58.2%,
at the same total energy. The delay-focused pair improves a further 26.5% over
the LFM pair but retains its unacceptable sidelobes. The normalized-knee pair
improves 11.6% while keeping a less extreme correlation trade-off.

The exact cancellation must not be treated as a hardware guarantee. Unequal
up/down transfer functions, acceleration during the pair, oscillator drift,
multipath, clipping, and quantization can break the symmetry. Those effects are
the next required model and bench tests.

## Evidence files

- [`waveform-metrics.csv`](data/fm-positioning/waveform-metrics.csv): equality
  checks, RMS bandwidth, CRLB, autocorrelation, and the mobile ambiguity point;
- [`ambiguity-cuts.csv`](data/fm-positioning/ambiguity-cuts.csv): ambiguity-peak
  delay and loss over -500 to +500 Hz, including the exact mobile Doppler;
- [`monte-carlo-toa.csv`](data/fm-positioning/monte-carlo-toa.csv): every AWGN
  and mobile condition;
- [`pareto-candidates.csv`](data/fm-positioning/pareto-candidates.csv): all 599
  monotone candidates and their four normalized objectives;
- [`pareto-front.csv`](data/fm-positioning/pareto-front.csv): the 212 strict
  non-dominated candidates and representative labels;
- [`paired-ambiguity.csv`](data/fm-positioning/paired-ambiguity.csv): up, down,
  half-sum timing, and half-difference Doppler displacement over the full grid;
- [`paired-monte-carlo.csv`](data/fm-positioning/paired-monte-carlo.csv): fixed
  total-energy pair results at zero and mobile Doppler;
- [`summary.json`](data/fm-positioning/summary.json): configuration,
  provenance, optimization definition, and compact metrics.

The next useful step is to disturb the ideal up/down symmetry with acceleration,
frequency-selective multipath, oscillator drift, and analog filter mismatch.
Only candidates that retain a useful advantage there should be mapped into
fixed point or RTL.
