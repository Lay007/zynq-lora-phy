# Full-packet ToA regression

[Русская версия](ru/joint-toa-regression.md)

`tools/joint_packet_regression.py` drives the actual SF7/L8 receiver RTL with
complete packets at 1 MS/s and alternating 62/63 PL clocks per sample. It checks
the final coarse/Q12 metadata, CRC, exact payload and the remaining header
deadline. It does not measure RF bias, inter-receiver synchronization or
hardware accuracy.

## Run

On Linux or WSL, install Verilator with a C++ toolchain and the project's Python
dependencies (`python -m pip install -e ".[dev]"`). From the repository root:

```sh
python tools/joint_packet_regression.py --suite baseline --out build/joint-baseline
python tools/joint_packet_regression.py --suite timing --out build/joint-timing
```

Each output directory must be new or empty. Previous evidence is never
overwritten. `--jobs` controls compilation parallelism; `--timeout` sets the
per-case simulation limit in seconds (default 300). Both suites run in the
`joint-full-packet` matrix in `.github/workflows/rtl-ci.yml`.

## Stimulus and truth

- `baseline`: the original 17 noise-free cases, with bit-identical quantized IQ.
  These cover both CFO signs at 418/1000/1500 Hz, fractional delays and arrival
  phases near symbol boundaries, with 8/12-symbol preambles.
- `timing`: 16 additional cases. Four phase/CFO/preamble/fraction combinations
  each run with SFO -20/+20 ppm, without noise and with seeded AWGN at 10 dB
  SNR in the 125 kHz signal bandwidth. This is a small deterministic matrix,
  not a statistical PER campaign or a full impairment cross-product.

The fractional delay uses the baseline's FFT translation with zero guards.
SFO then resamples the entire stream using linear interpolation:
`y[n] = x[n * (1 + sfo_ppm/1e6)]`. This sign agrees with the MATLAB channel
model; positive SFO moves events earlier. Linear interpolation is part of the
stimulus model and can affect the waveform. CFO is applied in receiver sample
coordinates after resampling. White complex noise covers the full sample
bandwidth; its variance is `Fs/BW * 10^(-SNR/10)` relative to unit packet power,
independent of guard length. The IQ scale is 400 before signed 16-bit rounding.
Out-of-range stimuli are rejected rather than wrapped or silently clipped.

For `S=1024`, `lead=2048+phase`, fractional delay `f`, preamble length `P`,
and sample-rate ratio `r=1+sfo_ppm/1e6`, the expected coordinates are:

```text
ToA = (lead + f + (P-8)*S) / r
header_start = (lead + f + (P+4.25)*S) / r
```

The ToA origin is the first of the retained eight preamble chirps, not
necessarily the first RF chirp. Neither coordinate is derived from detected
windows, decoded bytes or fitted timing. Fraction and SFO also affect the header
coordinate; previously the driver used the unshifted header coordinate.

## Acceptance and accounting

The original thresholds remain unchanged: absolute ToA error **strictly below
0.5 sample** and header margin **strictly above 96 samples**. Each case also
requires exactly one detection, one metadata record, one joint completion,
fraction within signed Q12 +/-0.5 sample, a complete trace, successful simulator
exit, payload CRC and exact transmitted payload.

A failed case or timeout is recorded and the following cases still run.
The final process exit is nonzero if any case fails. Infrastructure failures
such as a failed build stop the run; the initial summary retains the planned
count with the unexecuted cases marked missing.

Artifacts:

- `results.json`: checkpointed per-case outcomes, raw metadata, truth, failure
  reasons, latency, and IQ/log hashes;
- `summary.json`: planned/completed/missing counts, detection and metadata
  failures, CRC count, ToA bias, RMSE, absolute p95/p99, maximum and outlier count;
- `provenance.json`: complete case matrix, tool versions and hashes of RTL,
  reference ROM, stimulus generator, decoder and regression code;
- individual `.hex` stimuli, `.log` traces and `build.log`.

ToA statistics retain every unambiguous timestamp, including CRC failures and
outliers. Missing and duplicate timestamps have separate counts and are not
assigned zero error. No offset or drift is fitted out. Percentiles describe
only the observed deterministic cases, with no population confidence claim.
CI uploads JSON and logs; exact IQ remains in the local run directory.

Python tests exercise the accounting, failure handling, baseline IQ identity,
SFO sign, timing coordinates and seeded noise normalization without a simulator.
They complement, rather than replace, the full RTL runs.
