# MATLAB M1 floating-point acceptance

[Русская версия](ru/matlab-m1-acceptance.md)

M1 is complete at the floating-point algorithm boundary. The configured
receiver now accepts continuous complex IQ, finds complete LoRa packets,
resolves timing and carrier offset, decodes the header and payload, and reports
acquisition, pre-FEC, CRC, BER, and PER outcomes. The same MATLAB layer also
contains fractional ToA, calibrated TDoA observations, and a weighted 2D
multilateration solver. Simulink is deliberately not part of this acceptance.

## Receiver contract

```text
continuous configured IQ
  -> energy candidates + chirp-sequence candidates
  -> repeated-upchirp, sync-word, and downchirp validation
  -> joint timing/CFO estimate from upchirp and downchirp bins
  -> explicit or implicit header packet decode
  -> deinterleaving, FEC, dewhitening, CRC, payload
  -> detection, false-alarm, BER, and PER accounting
```

The chirp detector validates the configured sync transition and two SFD
downchirps. This lets it acquire signals below the per-sample energy floor
without accepting a repeated payload symbol as a preamble. Energy and chirp
candidates are both retained, including the mixed-amplitude case in which a
strong packet crosses the energy threshold and a weaker packet does not.

An upchirp alone cannot uniquely separate a whole-chip timing displacement
from CFO: both move its dechirped peak. For the downchirp the timing term
changes sign while the CFO term does not. The receiver therefore uses the
half-sum of the signed up/down bins for CFO and their half-difference for
timing. This correction is what made the coherent path deterministic on the
committed real-IQ set.

## Reproduce

MATLAB R2025a, from `model/matlab`:

```matlab
results = run_tests;
assertSuccess(results);

addpath examples
report = run_m1_acceptance;
```

`run_m1_acceptance` writes the raw tables and MAT report under `docs/data` and
the two acceptance figures under `docs/images`. The SNR in the stream campaign
is nominal active-packet power divided by complex noise-sample power. Silence
does not dilute the reference power.

## End-to-end packet evidence

The sensitivity sweep uses `L=Fs/BW=8`, CR 4/5, a 16-byte payload, and 20
packets per point. Every row had zero unmatched false-alarm candidates and zero
duplicate candidates. The SNR is per sample; the column in BW adds
10 log10(8) = 9.03 dB and is the axis of the PER bench and the recording tools
([SNR in the signal bandwidth](ber-methodology.md#snr-in-the-signal-bandwidth)).

| SF | SNR per sample, dB | SNR in BW, dB | acquired / 20 | PER |
|---:|---:|---:|---:|---:|
| 5 | -14 / -12 / -10 / -8 | -5 / -3 / -1 / +1 | 0 / 2 / 18 / 20 | 1 / 0.95 / 0.20 / 0 |
| 7 | -18 / -16 / -14 / -12 | -9 / -7 / -5 / -3 | 1 / 16 / 20 / 20 | 1 / 0.90 / 0 / 0 |
| 9 | -24 / -22 / -20 / -18 | -15 / -13 / -11 / -9 | 0 / 10 / 20 / 20 | 1 / 0.95 / 0.05 / 0 |

![End-to-end LoRa stream sensitivity](images/lora-end-to-end-sensitivity.png)

The mode matrix exercises all 32 `SF5...SF12 x CR 4/5...4/8`
combinations at `L=4`, two packets per combination: 64/64 packets were
acquired and decoded with PER zero. Four five-packet impairment cases also
gave 20/20 exact payloads: baseline; 1.5 kHz CFO plus 20 ppm SFO and 1.75
sample delay; fractional-delay multipath; and I/Q imbalance, DC offset, 12-bit
ADC quantization, and clipping control.

The committed SX1262 -> ZynqSDR targeted captures remain the independent real
regression. All 130/130 transmissions pass acquisition, header, CRC, and exact
payload comparison; pre-FEC BER is 2.227%. After joint timing/CFO correction,
all 130 select the FFT correlator and none require the retained polyphase guard
path. The older 118/130 nominal and 56/74 hybrid split was caused primarily by
synchronization ambiguity, not proven chirp-shape mismatch.

Raw evidence:

- [`lora-end-to-end-sensitivity.csv`](data/lora-end-to-end-sensitivity.csv)
- [`lora-end-to-end-mode-coverage.csv`](data/lora-end-to-end-mode-coverage.csv)
- [`lora-end-to-end-impairments.csv`](data/lora-end-to-end-impairments.csv)
- [targeted hardware `performance-summary.json`](../captures/reference/2026-08-07-heltec-v43-zynqsdr-targeted/performance-summary.json)

## ToA and TDoA evidence

The [fractional-ToA AWGN plot](images/toa-accuracy-awgn.png) uses 100 trials at each of five SNR levels from −25 to −5 dB (500 trials in total). The [MATLAB plotting example](../model/matlab/examples/plot_toa_accuracy.m) specifies this run.

The sub-sample accuracy table below uses a separate [archived CSV](data/toa-interpolator-accuracy.csv) with 200 trials at each of +20, +10, 0, −5 and −10 dB (1,000 trials in total).

### Sub-sample accuracy, and why the interpolator was replaced

The coarse timestamp resolves one sample, which is **1199 m** at
`Fs = 250 kHz`. Everything TDoA can do rests on the fractional part.

| SNR | std | p95 |
|---:|---:|---:|
| +20 dB | 8.5 m | 14.0 m |
| +10 dB | 10.6 m | 20.3 m |
| 0 dB | 22.9 m | 49.3 m |
| −5 dB | 39.1 m | 81.5 m |
| −10 dB | 68.6 m | 142.2 m |

These figures follow a fix. The estimator originally fitted a three-point
parabola to correlation **power** and measured about 77 m across the whole
range — and it was the flatness that gave it away, because an error that
does not move between +20 dB and −5 dB is not noise.

A noiseless delay sweep confirmed it: the estimate traced a clean S-curve,
zero at whole samples and worst between them, 0.17 samples peak to peak with
nothing in the chain but the interpolator. A chirp correlation peak is closer
to a Gaussian than to a parabola, so fitting the wrong shape leaves a
systematic error rather than a random one:

| Three-point fit to | Noiseless bias RMS | |
|---|---:|---:|
| correlation power | 0.0625 samples | 75.0 m |
| correlation magnitude | 0.0347 | 41.6 m |
| **log magnitude (Gaussian)** | **0.0066** | **8.0 m** |

The distinction matters for positioning rather than tidiness. A deterministic
bias repeats packet to packet, so averaging does not remove it, and across
three stations it does not cancel — it becomes a position offset. The error
now grows with noise, which is what an estimator's error is supposed to do.

Raw table:
[`toa-interpolator-accuracy.csv`](data/toa-interpolator-accuracy.csv),
regenerated by `export_toa_accuracy`.

**These are synthetic AWGN numbers at `L = 2`.** They are not a bench
characteristic: no cable calibration, no multipath, and no hardware clock is
involved.

### The fix is not validated on hardware, and this capture cannot do it

An attempt was made on `toa-sf7-bw125.cf32`, the fixed-geometry 50-packet
run recorded for timing repeatability. It cannot resolve the question, and
the reason is worth recording so the attempt is not repeated.

With geometry fixed and a nominal transmit interval, absolute ToA against
packet index should lie on a line whose residual is the estimator's own
contribution. Measured, the residual is **2139 samples**, and it is the same
to four significant figures for both interpolators — 2139.3311 against
2139.3346. The difference between them, some 0.0035 samples, is buried under
a residual six orders of magnitude larger.

The residual is not the estimator. The transmitter's interval jitters by
hundreds of microseconds, which is visible in the manifest's own `host_utc`
timestamps; detection lands on an `M/4` hop grid; and 20 of 50 packets were
detected, so detection index does not track transmission number.

So the sub-sample improvement is **measured in simulation only**. Confirming
it on hardware needs an experiment where the transmitter's timing cancels:
two receivers on the same signal, so the TDoA difference removes the common
transmit instant, or a cabled loopback with a known delay. Neither exists
yet.
The calibrated 2D TDoA campaign uses four receivers around a 100 m by 80 m
area, uniformly distributed sources inside the array, known fixed receiver
delays, and 1,000 trials per timestamp-noise point.

| Timestamp noise per receiver | converged | position RMSE | 95th percentile |
|---:|---:|---:|---:|
| 0.2 ns RMS | 1000/1000 | 0.063 m | 0.109 m |
| 1 ns RMS | 1000/1000 | 0.310 m | 0.537 m |
| 5 ns RMS | 1000/1000 | 1.582 m | 2.713 m |

![Calibrated 2D TDoA accuracy](images/tdoa-positioning-accuracy.png)

These are synthetic geometry results, not a claim about the present hardware
bench. Hardware ToA/TDoA still requires common clocks and epochs, PL sample
counters, cable/RF/ADC/DSP delay calibration, and measured uncertainty.

## Boundary of M1

The accepted receiver is configuration-aided: SF, BW, sync word, IQ polarity,
and implicit-header parameters are supplied for each pass. Blind multi-mode
classification, overlapping LoRa collisions, interference cancellation, and a
real-time streaming implementation are outside M1. The detector is an offline
floating-point reference and is intentionally compute-heavy. Those limits are
inputs to Simulink architecture work, not hidden claims of completion.
