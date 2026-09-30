# M2 acceptance: Simulink measurements

[Русская версия](ru/simulink-m2-acceptance.md)

Measured results for the executable Simulink model. Every number here comes
from a committed script and a committed table; nothing is estimated. The
interface contract, toolchain, and vector format are in
[M2 foundations](simulink-m2-interfaces.md).

M2 is **complete**. This document records the measured acceptance evidence and
the boundaries deliberately deferred to M3 and later hardware milestones.

> Historical scope note: statements below that HDL cosimulation was unavailable
> describe the M2 acceptance date. M3 now has a passing HDL Verifier/Vivado XSim
> run recorded in `docs/data/simulink-m3-hdl-cosimulation.csv`.

## Reproducing

```matlab
cd model/simulink
results = run_simulink_regression;   % toolchain, double, joint, reset, acquisition, blind, frontend, framing, sfd
results = run_simulink_regression(Suites=["fixed" "real"]);   % long campaigns
report = run_hdl_generation;         % Verilog and resource counts
```

The command raises an error on any mismatch, so

```bash
matlab -batch "cd model/simulink; run_simulink_regression"
```

returns a nonzero exit code when Simulink and MATLAB disagree. This was
verified by forcing the tolerance to `1e-20`: the run exits with code 1.

Deleting `model/simulink/generated/` before the run is safe and is part of the
check — every model is rebuilt from its generation script.

## Stage-by-stage double equivalence

The committed golden `input` stage is the stimulus, so only the Simulink path
is under test. All 15 acceptance cases pass.

| Result | Value |
|---|---|
| Cases | 15 / 15 |
| Symbol decisions identical to MATLAB | 15 / 15 |
| Worst relative RMS error, any stage | `8.334e-16` |
| Worst confidence absolute error | `1.887e-15` |
| Reference ROM vs golden `conjReferenceSpectrum` | `0` (bit-identical) |
| Acceptance tolerance applied | relative RMS ≤ `1e-12` |

Per comparison point, worst case over all 15 cases:

| Stage | Elements compared | Max absolute error | Worst relative RMS |
|---|---:|---:|---:|
| `fftM` | 16384 | `1.400e-13` | `4.051e-16` |
| `product` | 16384 | `1.150e-11` | `4.110e-16` |
| `partition` | 7904 | `1.140e-11` | `4.110e-16` |
| `fftN` | 7904 | `2.572e-12` | `8.334e-16` |
| `magnitudeSquared` | 7904 | `5.821e-10` | `5.786e-16` |

Absolute error grows with stage scale and is meaningless on its own: `fftM`
values reach `M` times the input amplitude, and `magnitudeSquared` is a square.
Relative RMS stays at the `1e-16` level everywhere, which is double-precision
rounding, not an algorithmic difference.

Raw tables:

- [`simulink-m2-stage-comparison.csv`](data/simulink-m2-stage-comparison.csv) —
  one row per case and stage.
- [`simulink-m2-case-summary.csv`](data/simulink-m2-case-summary.csv) — one row
  per case with decisions, confidence, latency, and throughput.

## Latency and throughput

Latency is counted from the **last input sample of a symbol window**, which is
the earliest instant at which that symbol could possibly be decided. All values
are in sample clocks; the DUT runs one sample per clock.

| SF | L | N | M | FFT_M latency | Symbol latency | Symbol interval |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 4 | 32 | 128 | 180 | 419 | 128 |
| 5 | 8 | 32 | 256 | 313 | 680 | 256 |
| 7 | 1 | 128 | 128 | 180 | 614 | 128 |
| 7 | 2 | 128 | 256 | 313 | 875 | 256 |
| 7 | 4 | 128 | 512 | 567 | 1385 | 512 |
| 7 | 8 | 128 | 1024 | 1084 | 2414 | 1024 |
| 9 | 2 | 512 | 1024 | 1084 | 3185 | 1024 |
| 10 | 1 | 1024 | 1024 | 1084 | 4214 | 1024 |
| 12 | 1 | 4096 | 4096 | 4143 | 16476 | 4096 |

Throughput is **one symbol per `M` samples with no gaps**. The measured symbol
interval equals `M` exactly in every multi-symbol case, so the pipeline sustains
the full input rate and never stalls. This is the measurement behind the
no-backpressure interface decision.

Symbol latency depends on `N` as well as `M`: at `M = 1024` it is 2414 samples
for `N = 128` and 4214 for `N = 1024`, because the second FFT and the peak
tracker both scale with `N`.

### What these numbers are not

They are Simulink sample-clock latencies. They are **not** hardware latency, and
no clock frequency, `Fmax`, or resource figure exists yet. Nothing here has been
synthesized.

## Fixed-point configuration

### What is chosen and what is derived

Integer bits at every chosen boundary come from measured range analysis over
the committed golden vectors (`lora_sim.stage_ranges`) plus one guard bit, so
the swept word length only trades fraction bits. Policy is held constant so a
sweep changes one variable at a time:

| Property | Value | Why |
|---|---|---|
| Rounding | `Floor` | truncation, the cheapest option in HDL |
| Overflow | `Saturate` | a wrap would move the `argmax` |
| Guard bits | 1 | one binary doubling of the measured range |

Chosen boundaries: input IQ, reference ROM, complex multiply, partition
accumulator, second FFT after the `1/M` scale, magnitude², spectrum sum, and
confidence.

The two FFT widths are **not** chosen. `dsphdl.FFT` runs unnormalized, so its
output word length is its input word length plus `log2(FFTLength)` with the
fraction length unchanged. They are reported as derived values.

### Why decision preservation alone is not a criterion

The obvious acceptance rule — "the symbol decisions must not change" — is
satisfied by word lengths that are numerically useless, and the sweep says so
plainly. Every acceptance case keeps its exact MATLAB symbol at **8 bits**,
while the relative RMS error of the correlator output reaches **118%**.

The reason is in the decision-margin column: the relative gap between the
winning bin and the runner-up spans 0.16 to 1.00 across the acceptance set and
is mostly above 0.8. Breaking an `argmax` with that much separation takes an
enormous amount of quantization noise.

But `argmax` is not the only consumer. `decode_packet_soft` uses per-bin
magnitudes as reliability information, and a demodulator whose output is wrong
by tens of percent is worthless there. The selection therefore requires both:

1. every acceptance case decides the same symbol as MATLAB, and
2. the worst relative RMS error over every stage stays at or below
   `MaxRelativeRms`, default `1e-2`.

The 1% bound is an engineering choice, not a derived limit, and is stated as
one. Its rationale: at the −10 dB SNR acceptance point the magnitude² values
already vary by order 100% from noise alone, so holding quantization to 1%
keeps it roughly 20 dB below the physical variation the soft decoder is
designed to work with.

### Sweep results

15 cases at each word length, 90 fixed-point simulations, 3161 s total.

| Word length | Cases | Symbol matches | Worst relative RMS | Worst confidence error | Smallest decision margin |
|---:|---:|---:|---:|---:|---:|
| 8 | 15 | 15 | `1.180e+00` | `3.628e-01` | 0.160 |
| 10 | 15 | 15 | `2.922e-01` | `1.748e-01` | 0.227 |
| 12 | 15 | 15 | `7.334e-02` | `8.604e-02` | 0.232 |
| 14 | 15 | 15 | `1.805e-02` | `2.781e-02` | 0.236 |
| **16** | 15 | 15 | `4.561e-03` | `7.459e-03` | 0.237 |
| 18 | 15 | 15 | `1.142e-03` | `2.049e-03` | 0.237 |

Worst relative RMS per configuration:

| SF | L | M | 8 bits | 10 bits | 12 bits | 14 bits | 16 bits | 18 bits |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 4 | 128 | `1.902e-01` | `4.631e-02` | `1.205e-02` | `3.198e-03` | `8.980e-04` | `2.266e-04` |
| 5 | 8 | 256 | `1.242e-01` | `5.669e-02` | `1.434e-02` | `3.396e-03` | `8.579e-04` | `2.330e-04` |
| 7 | 1 | 128 | `1.993e-01` | `5.043e-02` | `1.242e-02` | `3.161e-03` | `7.856e-04` | `1.960e-04` |
| 7 | 2 | 256 | `1.675e-01` | `4.448e-02` | `1.063e-02` | `2.787e-03` | `6.844e-04` | `1.707e-04` |
| 7 | 4 | 512 | `1.751e-01` | `5.222e-02` | `1.227e-02` | `3.097e-03` | `7.987e-04` | `2.034e-04` |
| 7 | 8 | 1024 | `3.389e-01` | `1.133e-01` | `3.840e-02` | `9.696e-03` | `2.410e-03` | `5.635e-04` |
| 9 | 2 | 1024 | `3.943e-01` | `8.954e-02` | `2.271e-02` | `5.638e-03` | `1.419e-03` | `3.667e-04` |
| 10 | 1 | 1024 | `5.846e-01` | `1.492e-01` | `3.644e-02` | `8.877e-03` | `2.292e-03` | `5.846e-04` |
| 12 | 1 | 4096 | `1.180e+00` | `2.922e-01` | `7.334e-02` | `1.805e-02` | `4.561e-03` | `1.142e-03` |

Every point divides the error by roughly four per two added bits, as expected
for a purely fractional refinement.

**Selected: 16 bits** for the whole acceptance set. It is the smallest swept
word length that satisfies both criteria; 14 bits fails only because of
`SF12, L=1` at `1.805e-02`.

**14 bits is sufficient for the first hardware target.** At `SF7, L=8` — BW
125 kHz with `Fs = 1 MHz` — the error at 14 bits is `9.696e-03`, inside the 1%
bound. The larger word length is driven by the widest FFT in the acceptance
set, not by the configuration the board will run first.

The selection is derived from the committed table; the two criteria are encoded
in `run_fixed_point_sweep` as `MaxRelativeRms`, so re-running reproduces it
without re-deriving it by hand.

### Selected types at 16 bits

| SF | L | input | reference | product | accumulator | fftN | magnitude² | FFT_M out | FFT_N out |
|---:|---:|---|---|---|---|---|---|---:|---:|
| 5 | 4 | `sfix16_En11` | `sfix16_En9` | `sfix16_En3` | `sfix16_En3` | `sfix16_En6` | `ufix16_En0` | 23 | 21 |
| 5 | 8 | `sfix16_En14` | `sfix16_En8` | `sfix16_En2` | `sfix16_En2` | `sfix16_En6` | `ufix16_En-1` | 24 | 21 |
| 7 | 1 | `sfix16_En14` | `sfix16_En10` | `sfix16_En6` | `sfix16_En6` | `sfix16_En7` | `ufix16_En1` | 23 | 23 |
| 7 | 2 | `sfix16_En14` | `sfix16_En9` | `sfix16_En4` | `sfix16_En4` | `sfix16_En6` | `ufix16_En-1` | 24 | 23 |
| 7 | 4 | `sfix16_En14` | `sfix16_En8` | `sfix16_En2` | `sfix16_En2` | `sfix16_En5` | `ufix16_En-3` | 25 | 23 |
| **7** | **8** | `sfix16_En10` | `sfix16_En7` | `sfix16_En-1` | `sfix16_En-1` | `sfix16_En4` | `ufix16_En-5` | 26 | 23 |
| 9 | 2 | `sfix16_En12` | `sfix16_En8` | `sfix16_En1` | `sfix16_En1` | `sfix16_En4` | `ufix16_En-5` | 26 | 25 |
| 10 | 1 | `sfix16_En14` | `sfix16_En8` | `sfix16_En3` | `sfix16_En3` | `sfix16_En4` | `ufix16_En-5` | 26 | 26 |
| 12 | 1 | `sfix16_En14` | `sfix16_En7` | `sfix16_En1` | `sfix16_En1` | `sfix16_En2` | `ufix16_En-9` | 28 | 28 |

Negative fraction lengths are not a mistake: `magnitudeSquared` at `SF7, L=8`
reaches `1.05e6`, so the type is a 16-bit unsigned value scaled by `2^5`. The
FFT output columns are derived, not chosen.

Raw tables:

- [`simulink-m2-fixed-point-sweep.csv`](data/simulink-m2-fixed-point-sweep.csv)
- [`simulink-m2-fixed-point-cases.csv`](data/simulink-m2-fixed-point-cases.csv)
- [`simulink-m2-fixed-point-stages.csv`](data/simulink-m2-fixed-point-stages.csv)

### Range analysis is scoped, and that is a limitation

Integer bits follow the measured maxima of the acceptance corpus. A different
input regime — a front end with more headroom, a different AGC target, an
interferer — requires re-running the range analysis. The word length is the
transferable result; the fraction lengths are not.

## Joint timing/CFO estimator

The second subsystem separates whole-chip timing from carrier offset using the
signed dechirp bins of one preamble upchirp and one SFD downchirp. Because both
half-sum and half-difference are exact multiples of `1/2`, the whole estimator
is integer arithmetic in units of half a bin, and the DUT is compared against
MATLAB on **exact equality** rather than a tolerance.

| SF | L | N | Bin pairs | Coverage | Mismatches | Rejected pairs |
|---:|---:|---:|---:|---|---:|---:|
| 5 | 8 | 32 | 1 024 | exhaustive | 0 | 0 |
| 7 | 8 | 128 | 16 384 | exhaustive | 0 | 0 |
| 7 | 1 | 128 | 16 384 | exhaustive | 0 | 0 |
| 9 | 2 | 512 | 262 144 | exhaustive | 0 | 0 |

295 936 bin pairs, every one enumerated: this is a proof over the whole input
domain, not a sample. All five outputs — `correctionSamples`, `cfoHalfBins`,
`timingHalfChips`, `estimateValid`, `timingRejected` — match.

Raw table: [`simulink-m2-joint-sync.csv`](data/simulink-m2-joint-sync.csv).

The zero in the last column is itself a result. The plausibility guard that
zeroes an implausible timing correction is **unreachable** for in-range bins:
signed bins bound `|timingChips|` by `(N-1)/2`, so the correction cannot exceed
`(N-1)·L/2`, which never reaches the `M/2 + L` limit. The branch is kept for
callers that might search a wider range, and both the MATLAB test and this
Simulink run now pin it as inactive rather than leaving it silently dead.

The estimator consumes bins, not samples. What produces those bins is now in the
model: blind packet-start detection is described below and yields the coarse
whole-chip offset that this estimator refines to half a chip.

## Frequency-only estimator and present accuracy

The separate `frequency-estimator` keeps only the CFO half-sum from the joint
block. It accepts `upBin`, `downBin`, and `binValid`, registers both boundaries,
and returns `cfoHalfBins` plus `estimateValid` after two clocks. Its exhaustive
regression uses the unchanged joint timing/CFO MATLAB model as the golden
reference:

| SF | L | Bin pairs | Mismatches | Resolution at BW125 | Maximum nearest-bin error |
|---:|---:|---:|---:|---:|---:|
| 5 | 8 | 1 024 | 0 | 1953.125 Hz | 976.563 Hz |
| 7 | 8 | 16 384 | 0 | 488.281 Hz | 244.141 Hz |
| 7 | 1 | 16 384 | 0 | 488.281 Hz | 244.141 Hz |
| 9 | 2 | 262 144 | 0 | 122.070 Hz | 61.035 Hz |

The output quantum is `BW/(2·2^SF)` because one integer `cfoHalfBins` unit is
half an FFT bin; oversampling `L` cancels. Thus the present SF7/BW125 PL
estimate has a 488.281 Hz step and at most ±244.141 Hz ideal quantization error
when both peaks select the nearest bins. At SF7/BW500 those numbers become
1953.125 Hz and ±976.563 Hz.

This is not a measured absolute-frequency accuracy. Noise can make a peak
select the wrong bin, and the SDR and transmitter references remain in the
observed CFO. Absolute carrier is the configured SDR centre plus the estimated
offset. The floating-point IQ inspector also has a finer phase-progression
residual-CFO estimate, but that path is not in PL.

Raw table:
[`simulink-m2-frequency-estimator.csv`](data/simulink-m2-frequency-estimator.csv).

## Real SX1262 symbol windows

The committed SX1262 → ZynqSDR captures are decoded by the authoritative MATLAB
receiver, the corrected symbol windows the correlator actually consumed are
extracted, normalized to unit RMS per packet, and replayed through the
fixed-point DUT at 16 bits.

| SF | L | M | Packets | Symbols | fixed == float | nominal == receiver | worst relative RMS |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 5 | 8 | 256 | 30 | 2340 | 2340 | 2340 | `8.409e-04` |
| 6 | 8 | 512 | 30 | 2040 | 2040 | 2040 | `8.772e-04` |
| 7 | 8 | 1024 | 70 | 4060 | 4060 | 4060 | `1.399e-03` |
| **total** | | | **130** | **8440** | **8440** | **8440** | `1.399e-03` |

All 130 committed packets, all 8440 consumed symbols: the 16-bit fixed-point
DUT decides exactly the symbol the floating-point correlator decides, and both
decide exactly what the MATLAB packet receiver decided. Worst confidence error
is `6.704e-03`. Zero packets contain a single differing symbol.

The `nominal == receiver` column is worth its own sentence. The DUT uses the
nominal reference chirp; the packet receiver additionally estimates a
phase-aligned reference from the preamble. On these captures that adaptive
reference changes **no** symbol decision, so the feature the DUT does not
implement is, for this corpus, not load-bearing at the symbol level. That is a
measurement on 130 packets, not a general claim.

Range analysis for this run is collected from the real windows themselves.
Selected types:

| SF | L | input | reference | product | accumulator | fftN | magnitude² |
|---:|---:|---|---|---|---|---|---|
| 5 | 8 | `sfix16_En13` | `sfix16_En8` | `sfix16_En2` | `sfix16_En2` | `sfix16_En6` | `ufix16_En-1` |
| 6 | 8 | `sfix16_En13` | `sfix16_En7` | `sfix16_En1` | `sfix16_En1` | `sfix16_En5` | `ufix16_En-3` |
| 7 | 8 | `sfix16_En13` | `sfix16_En7` | `sfix16_En0` | `sfix16_En0` | `sfix16_En3` | `ufix16_En-6` |

Raw tables:

- [`simulink-m2-real-iq-groups.csv`](data/simulink-m2-real-iq-groups.csv)
- [`simulink-m2-real-iq-packets.csv`](data/simulink-m2-real-iq-packets.csv)

### What 8440 symbols means, and a defect this run found

8440 is the number of symbols the decoder **consumed**: 78 per packet at SF5,
68 at SF6, 58 at SF7. It is not the number of windows the receiver produced.
While searching timing, the receiver demodulates every window up to an
energy-derived packet end, which overshoots: an SF7 packet yields about 133
windows of which 58 carry signal and the rest are the noise floor after the
transmission stopped.

The first version of this regression replayed all of them and reported 45%
agreement. The stage errors did not agree with that number — SF5 showed 0.6%
relative RMS with 46% of decisions differing, which is impossible — and the
contradiction is what exposed the cause. In the noise windows the fixed-point
`magnitudeSquared` was **identically zero across every bin**: their peak is
around `0.13` against a corpus range of `2.4e6`, so the whole spectrum fell
below the LSB and `argmax` returned bin 0. The double DUT on the same packet
was 133/133, which is what proved the structure was sound and the stimulus was
not.

Two things are worth keeping from that. Scoring `argmax` on noise is
meaningless in floating point too — it simply agrees with itself and hides. And
fixed point turned a silent nonsense into a loud zero, which is the more
useful failure mode.

## HDL Coder compatibility

The M2 criterion is not only that Simulink matches MATLAB but that the design
is accepted by HDL Coder's checks. `run_hdl_compatibility_check` runs `checkhdl`
on each named DUT with `TargetLanguage` set to Verilog.

| Target | DUT | Errors | Warnings |
|---|---|---:|---:|
| `fft-correlator-double` | `lora_fft_correlator_hdl/DUT` | 7 | 2 |
| **`fft-correlator-fixed`** | `lora_fft_correlator_hdl/DUT` | **0** | 2 |
| **`joint-timing-cfo`** | `lora_joint_sync_hdl/DUT` | **0** | 2 |

The checked DUTs are built with `IncludeVerificationTaps=false`, so the HDL
boundary carries only production signals and the stage taps used by the
regression never reach generated hardware.

| Target | Errors | Warnings |
|---|---:|---:|
| `fft-correlator-double` | 7 | 2 |
| `fft-correlator-fixed` | 0 | 2 |
| `acquisition` | 0 | 2 |
| `joint-timing-cfo` | 0 | 2 |

The three DUTs that are meant to become hardware pass with zero errors. The
double model's seven errors are the expected and correct result: `Double and
Single data types are not supported for HDL code generation`. A double model is
a simulation reference, not an HDL target, and it is checked only so that
the difference is on record.

The two warnings are identical on all three and are informational: Verilog
flattens vector signals regardless of `ScalarizePorts`, and sharing HDL between
identical atomic subsystems needs `Default parameter behavior` set to
`Inlined`. One message on the fixed DUT is worth carrying into M3: the
confidence divider uses a `ShiftAdd` architecture and therefore adds latency
that the current sample-clock latency table does not include.

Raw tables:
[`simulink-m2-hdl-compatibility.csv`](data/simulink-m2-hdl-compatibility.csv),
[`simulink-m2-hdl-messages.csv`](data/simulink-m2-hdl-messages.csv).

### checkhdl is not the gate; generation is

An earlier version of this document treated a clean `checkhdl` as proof that a
DUT is HDL-ready. That is wrong, and the acquisition subsystem is the
counterexample: `checkhdl` reported **0 errors**, and `makehdl` then refused to
generate it.

```text
Found unsupported division expression for HDL code generation;
Signed input data type is not supported for division with Floor RoundMode
```

The cause was `mod(bin - target + N/2, N)` in the circular-distance
calculation. `mod` on a signed value is a division, and HDL Coder will not
generate a signed division with Floor rounding. Both bins are in `[0, N)`, so
the difference is in `(-N, N)` and one comparison fixes the wrap without any
division:

```text
delta = bin - target;
if delta >=  N/2, delta = delta - N; end
if delta <  -N/2, delta = delta + N; end
```

The joint estimator had avoided `mod` from the start and generated cleanly,
which is why the difference showed up only here. The rule this establishes:
**a subsystem counts as HDL-ready when `makehdl` produces Verilog, not when
`checkhdl` is quiet.** `run_hdl_generation` is therefore part of the
acceptance path rather than an optional extra.

### Two defects this check found

`checkhdl` earned its place by rejecting a real boundary error rather than a
style issue:

```text
Illegal conversion to or from floating-point in .../DUT/CastInput
```

The DUT contained a `Data Type Conversion` turning a `double` input port into
the fixed-point sample type. That is convenient in simulation and meaningless
in hardware, where the ADC already delivers fixed-point samples. The quantizer
now sits in the harness, one block earlier; the numbers are identical and the
HDL boundary no longer contains floating point.

The divider was the second: HDL Coder accepts only `Zero` or `Simplest`
rounding on a divide and requires saturation. Confidence is a ratio of
non-negative quantities, so rounding toward zero is identical to the `Floor`
used everywhere else and the change costs nothing.

Two mechanical traps are recorded because they cost time. `checkhdl` compiles
the model, so the harness `From Workspace` sources must have stimulus in the
base workspace or the model fails to initialize before any check runs. And HDL
Coder settings go through `hdlset_param`; `set_param`'s `TargetLang` is
Simulink Coder's C/C++ selector and rejects `"Verilog"`.

A third trap produced a wrong result rather than an error. In the `checkhdl`
message struct the `type` field is `model` or `block` — the severity is in
`level`. Counting errors by `type` reported "0 errors, 0 warnings" while real
findings were present. The first published version of this table was wrong for
exactly that reason.

### What this does not prove

`checkhdl` is a compatibility checker, not a compiler. `makehdl` has not been
run, no Verilog exists, no cosimulation has been performed, and nothing has
been synthesized. There are no resource, `Fmax`, or power numbers, and none are
claimed.

## Reset behavior and timestamp metadata

`resetIn` clears the three counters and both streaming FFTs. Nothing else needs
it: the accumulator delay line is gated off for the first `N` bins of a symbol
and the peak tracker re-initializes at bin 0, so neither can read pre-reset
state once the counters restart. That is an architectural property rather than
an assumption, so it is tested rather than asserted.

`run_reset_regression` drives one waveform, asserts reset, drives a second
waveform in the same simulation, and requires the second half to match a
standalone run of that waveform exactly. It also requires the sample counter to
restart at zero.

| SF | L | M | Symbols before reset | Symbols after reset | Match standalone | Timestamps restart |
|---:|---:|---:|---:|---:|---|---|
| 5 | 2 | 64 | 3 | 2 | yes | yes |
| 7 | 8 | 1024 | 3 | 2 | yes | yes |

One detail cost a debugging cycle and is worth recording: asserting reset on the
same cycle as the first valid sample makes the streaming FFT discard that frame.
The reset pulse has to land on an idle cycle before data starts, which is what
the harness now does.

`symbolSampleCount` carries the sample index of each symbol's first sample,
latched at `symbolBoundary` and queued through the pipeline until the decision
emerges. The stage regression checks it on every acceptance case: the timestamps
must be exactly `0, M, 2M, …`, and the maximum error is `0` in all 15.

`fractionalToaSamples` is implemented by a separate sample-grid interpolator.
The correlator still provides the coarse count; once acquisition has narrowed
the matched-filter peak to three adjacent sample lags, the interpolator fits a
Gaussian to their magnitudes. It must not be fed three neighbouring chip-rate
FFT bins: those would describe a fractional *bin*, not a sub-sample ToA.

The fixed-point DUT uses a 64-entry mantissa table for `log2` and agrees with
`lora_phy.fractional_toa_from_triplet` within **0.382 m** over 19 real-chirp
peak shapes. Its RMS error against the injected synthetic delay is **7.941 m**,
while one coarse sample is **1199 m**. These are model-regression numbers, not
an accuracy claim for the hardware bench.

Raw table: [`simulink-m2-reset.csv`](data/simulink-m2-reset.csv).

The atomic coarse/fractional metadata join is covered separately by
`run_timestamp_metadata_regression`: coarse-first, fractional-first, same-cycle
arrival, reset of a partial record, duplicate-fragment overflow and preservation
of the original fragment all pass. The focused regression and CSV artifact were
recorded by
[CI run 32837815018](https://github.com/Lay007/zynq-lora-phy-positioning/actions/runs/32837815018).

## Acquisition: preamble and sync-word acceptance

The third subsystem consumes the correlator's symbol stream and decides whether
what it has seen looks like a LoRa acquisition sequence: `PreambleSymbols`
upchirps near bin 0, then two sync symbols near the bins the sync word encodes,
each within one bin on a circular metric.

Like the joint estimator this is integer arithmetic on bins, so the DUT is
compared with `lora_phy.validate_acquisition_bins` on **exact equality**.

| SF | Preamble symbols | N | Sequences | Accepted by MATLAB | Sync mismatches | Preamble mismatches | Failed-flag mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 7 | 8 | 128 | 205 | 2 | 0 | 0 | 0 |
| 5 | 8 | 32 | 205 | 2 | 0 | 0 | 0 |
| 9 | 6 | 512 | 205 | 2 | 0 | 0 | 0 |

615 sequences, zero mismatches on all three outputs. Each configuration mixes
the cases that matter — exact acquisition, one bin of drift including
wrap-around at bin 0, drift outside tolerance on the preamble, drift outside
tolerance on the sync word, an entirely wrong sync word — with 200 seeded
random sequences that are essentially always rejections. Only 2 of 205 are
accepted, which is the point: a detector that accepts everything would pass a
test that only fed it valid input.

Raw table: [`simulink-m2-acquisition.csv`](data/simulink-m2-acquisition.csv).

One constant is pinned by its own test because getting it wrong is a classic
and expensive error: LoRa encodes each sync-word nibble as a symbol index
multiplied by **8**, a fixed scale, not `2^(SF-4)`. The MATLAB test checks the
mapping exhaustively over all 256 sync words and across SF7…SF12.

### What this subsystem is not

It validates a **symbol-aligned candidate** using absolute bin targets: the
preamble at bin 0 and the sync word at `8 x nibble`. That is the correct check
once timing has already been corrected, and it is the wrong one before that.
Finding a packet in the first place is the next section; the section after it
shows realignment putting the preamble back on bin 0 and the sync word back on
8 and 16, which is precisely the domain this FSM was written for.

## Blind packet-start detection

This subsystem finds packets rather than confirming them, and it turned out to
be far cheaper than this document previously predicted. The prediction is quoted
and corrected in the resource section below.

### Why no sliding correlation is needed

The expected cost came from assuming a search over sample offsets. There is no
such search, because of a property of the waveform itself.

The preamble is a literal repetition of one upchirp, so the transmitted block is
periodic with `samplesPerSymbol`. Any window of that length is therefore a
cyclic rotation of the reference chirp, and a rotation still dechirps to a clean
tone. Take a window starting `d` chips after a symbol boundary: at local chip
`c` it carries signal chip `mod(c + d, N)`, whose normalised frequency is
`mod(c + d, N)/N - 1/2`, while the conjugate reference contributes
`-(c/N - 1/2)`. The product sits at `d/N` for every `c`. So

```text
bin = d, the number of chips elapsed since the last symbol boundary
```

Two consequences. Consecutive windows one symbol apart land on the **same** bin
whatever the alignment is, so the preamble shows up as a run of equal bins in a
correlator that is simply left running. And the bin is not a nuisance value: it
*is* the whole-chip timing offset, so acquisition and coarse timing come out of
the same measurement.

Measured against real samples at SF7, `L = 8`, the identity holds to the
rounding:

| Sample offset | CFO (bins) | Predicted `d + cfo` | Measured bin |
|---:|---:|---:|---:|
| 137 | 0 | 110.875 | 111 |
| 137 | 3 | 113.875 | 114 |
| 999 | 0 | 3.125 | 3 |
| 1023 | 3 | 3.125 | 3 |

### Why the sync check is relative

CFO displaces the dechirped tone as well, so the bin is `d + cfoBins` rather
than `d`. On an upchirp-only preamble the two are indistinguishable — separating
them is what the SFD downchirp pair is for.

That is why this subsystem checks the sync word at `preambleBin + 8 x nibble`
instead of at absolute positions. CFO moves the preamble and the sync symbols by
the same number of bins, so a relative check is invariant to it and an absolute
one is not. In the table above the sync pair at offset 137 moves from
`[119 127]` to `[122 2]` under 3 bins of CFO, wrapping past `N`, while staying
exactly 8 and 16 bins from the preamble. The absolute checker rejects those very
same samples.

### Equivalence

Integer arithmetic throughout, so the DUT is compared with
`lora_phy.detect_preamble_run` on **exact equality**, per symbol rather than per
sequence — the DUT slides, re-evaluating on every symbol against a shift
register of the last `PreambleSymbols + 2` bins.

| SF | Preamble symbols | N | Symbols | Preamble found | Decision mismatches | Bin mismatches |
|---:|---:|---:|---:|---:|---:|---:|
| 7 | 8 | 128 | 669 | 4 of 4 | 0 | 0 |
| 5 | 8 | 32 | 718 | 4 of 4 | 0 | 0 |
| 9 | 6 | 512 | 613 | 4 of 4 | 0 | 0 |

2000 symbols, zero mismatches on all five outputs. The stimulus is correlator
bins from packets placed at sample offsets that are deliberately **not**
multiples of the oversampling factor, with noise down to −10 dB and CFO, plus
seeded random bins and hand-built edge cases at bins 0, 1, `N-1`, and `N-8`.

All **256 sync words** are swept on one configuration, because that is where the
DUT and the reference could most plausibly disagree: the DUT reduces the sync
target with a bitmask where the reference uses `mod()`. Zero mismatches. The
mask is exact here only because `N` is a power of two — and it is not a
micro-optimisation, since `mod()` on a signed value is a division with Floor
rounding that HDL Coder refuses to generate at all.

### The straddle: why preamble and sync are separate outputs

Splitting `preambleDetected` from `syncValid` is not cosmetic. On the
free-running grid a window can straddle two symbols. Deep inside the preamble
that costs nothing, because both halves are the same chirp and the bin is
unchanged. At the preamble-to-sync boundary it does cost: the window carries
half a preamble symbol and half a sync symbol, the N-point spectrum holds two
comparable peaks, and the peak tracker returns whichever is larger.

Measured at an offset near `M/2`, the first sync symbol is skipped entirely:

```text
SF9 place3: 258 258 258 258 258 258 258  274 274     (expected sync 266, 274)
SF5 place3:  18  18  18  18  18  18  18   26  26 2   (expected sync 26,  2)
```

An alignment sweep across one whole symbol, noiseless so that alignment is the
only variable, quantifies the gap:

| Decision | Alignments passing |
|---|---:|
| `preambleDetected` | 100 % (32 of 32) |
| `syncValid` on the free-running grid | 97 % |

Preamble detection is therefore usable as it stands, and sync validation on this
grid is not. The intended composition is to detect the preamble here, realign
the window grid by `chipsToBoundary` — which this subsystem already outputs and
which the sweep confirms to within one chip at every alignment — and validate
sync on the aligned grid, where no straddle exists.

Raw tables: [`simulink-m2-blind-detector.csv`](data/simulink-m2-blind-detector.csv)
and [`simulink-m2-blind-detector-offsets.csv`](data/simulink-m2-blind-detector-offsets.csv).

### False alarms

A detector that fires on noise is worse than none. Over 20 seeded noise-only
streams — roughly 600 sliding windows with no signal present — there are **zero**
detections. Requiring 8 consecutive bins within one bin of the first, plus two
sync bins on target, is a demanding predicate for uniform noise.

## Composing the subsystems: realignment

Each subsystem above is exact against MATLAB on its own. Wiring them into one
model checks something none of those regressions can see, and it immediately
found a defect that all of them passed.

### Realignment is a skip, not a phase

The correlator gained `resyncValid`/`resyncSkip`. The first implementation
loaded a new value into the framing counter, which looked right and was not:
the streaming FFT frames on its own count of valid samples, so the boundary
flag and the timestamps moved while the FFT framing stayed exactly where it
was. Measured, the symbol bins did not budge — the timestamp of the first
window moved from 2048 to 1673 and every bin was unchanged.

Withholding samples is what moves the grid. Dropping `s` samples shifts the
window grid by `s` relative to the stream, and for a preamble at bin `d` the
required advance is `chipsToBoundary * L = mod(-d, N) * L`. With that,
realignment does what it claims:

```text
free:   0 0 0  94 94 94 94 94 94 94 94  102 110      sync at 94+8, 94+16
resync: 0 0 0  94 94 | 0 0 0 0 0 0 |      8  16      absolute bins
```

After realignment the preamble sits at bin 0 and the sync word at 8 and 16 —
the domain where `lora_phy.validate_acquisition_bins` is the correct check.
The residual is sub-chip: at offset 137 the true offset is 93.75 chips, so
whole-chip alignment lands within a quarter of a chip.

### The preamble flag cannot wait for the sync word

Composition then exposed a real defect in the blind detector. It evaluated
`preambleDetected` only once the whole `PreambleSymbols + 2` register had
filled — that is, only after two windows of *sync word* had gone past. A
realignment derived from that flag therefore always arrived too late for the
packet that produced it, and lengthening the preamble does not help, because
the decision waits on the windows that follow the preamble rather than on the
preamble itself. Measured with a 20-symbol preamble, realignment landed at
symbol 26, well past the sync word at 24 and 25.

The fix is to define the preamble decision on preamble bins alone.
`lora_phy.detect_preamble_only` is now that definition and
`detect_preamble_run` calls it for its preamble half, so there is one rule
with two call sites. The DUT evaluates the preamble flag on the newest
`PreambleSymbols` bins as soon as they exist, and the joint decision on the
full window once it fills; the two deliberately refer to different windows.
Detection then moves from symbol 26 to symbol 12.

### What the composed model proves

The property worth checking is not "the blocks agree with MATLAB" — that was
already true while the front-end could not acquire a packet. It is that a
packet placed at a sample offset the receiver is never told ends up
demodulating to the same payload as an aligned one.

| Offset (samples) | Skip | chipsToBoundary·L | Detected at symbol | Common payload symbols |
|---:|---:|---:|---:|---:|
| 0 | 0 | 0 | 9 | 34 |
| 137 | 136 | 136 | 12 | 34 |
| 259 | 260 | 260 | 12 | 34 |
| 511 | 0 | 0 | 13 | 34 |

All four offsets recover the same 34 payload symbols, and every skip equals
`chipsToBoundary * L`. The offsets are deliberately not multiples of the
oversampling factor, so alignment is only ever recovered to within a chip and
the payload has to survive the sub-chip remainder.

The symbols around the SFD are excluded automatically rather than by index:
the check finds the longest run common to every offset, and the windows
consumed by the realignment transition are expected to differ.

Raw table: [`simulink-m2-frontend.csv`](data/simulink-m2-frontend.csv).

### What this still is not

Realignment fires once per reset. Re-arming after a packet ends belongs to
the framing state machine, which is not built. There is no SFD validation, so
nothing confirms that what follows the sync word is a downchirp pair, and
nothing routes header and payload symbols anywhere.

## M3 spike: generated Verilog and first resource numbers

Verilog generation was pulled forward out of order, deliberately. The largest
remaining M2 item was acquisition, and how to build a blind preamble search
looked like a resource question: whether to reuse the correlator at a coarse
stride or add a cheaper dedicated detector depends on what the correlator
already costs. That number did not exist, so it was measured.

`run_hdl_generation` generates Verilog for the hardware-bound DUTs and reads
HDL Coder's own reports.

| Target | Verilog files | Multipliers | Adders/Subtractors | Registers | 1-bit registers | RAMs | Multiplexers | I/O bits | Added latency |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `fft-correlator-fixed` (SF7, L=8, 16 bit) | 77 | 34 | 438 | 1869 | 28201 | 64 | 994 | 218 | 34 |
| `blind-detector` | 2 | 0 | 76 | 11 | 168 | 0 | 89 | 73 | 0 |
| `framing` | 2 | 0 | 4 | 2 | 24 | 0 | 17 | 85 | 0 |
| `sfd` | 2 | 0 | 10 | 4 | 26 | 0 | 23 | 64 | 0 |
| `acquisition` | 2 | 0 | 5 | 3 | 34 | 0 | 28 | 65 | 0 |
| `joint-timing-cfo` | 2 | 0 | 9 | 0 | 0 | 0 | 16 | 131 | 0 |
| `frequency-estimator` | 2 | 0 | 3 | 5 | 34 | 0 | 3 | 38 | 0 |
| `toa-interpolator` | 2 | 0 | 10 | 16 | 465 | 0 | 131 | 166 | 0 |

The correlator carries one adder and 32 register bits more than before
realignment existed: that is the skip counter and its comparison. Grid
realignment costs essentially nothing on top of the correlator. The blind
detector grew from 44 adders to 76 when the preamble decision was split out
of the joint one, since the two predicates are now evaluated over different
windows on every symbol.

All eight generate with zero HDL errors. The generated code is committed under
[`fpga/generated/`](../fpga/generated) and is never edited by hand: behavior
changes go back into MATLAB and Simulink and the code is regenerated.

The correlator costs **34 multipliers and 64 RAMs** at the first hardware
operating point, which is the budget everything else has to fit around. HDL
Coder's delay balancing adds **34 cycles** on top of the model, so hardware
symbol latency at SF7/L=8 is 2414 + 34 = **2448 sample clocks**, not the 2414
the Simulink table reports. The frequency-only estimator itself has three
inferred adders, 34 register bits, no multipliers, and no RAM. These are still
operator counts; the synthesis result below is the silicon number.

### A prediction this document got wrong

An earlier version of this section said, of the blind packet search:

> The blind packet search that is still missing therefore has the whole
> remaining budget to itself, and it is the part that will actually consume it.

That was wrong, and the reason is worth recording. The estimate assumed a
sliding correlation over sample offsets, which would indeed have dominated the
design. The preamble's periodicity removes the search entirely: detection reuses
the correlator output that already exists and adds a predicate over a shift
register of ten bins.

Measured rather than predicted, the blind detector costs **0 multipliers, 0
RAMs, no added latency, and 168 register bits** — against the correlator's 34
multipliers, 64 RAMs, and 28201 register bits. It is roughly 0.6 % of the
correlator's register bits and 17 % of its adders.

The remaining arithmetic item was fractional ToA. It runs on the three-point
sample-rate matched-filter peak, but it is invoked once per packet rather than
once per sample. That rate difference is what makes a 38-cycle shared-logarithm
and iterative-divider implementation useful: latency is cheap here, while a
fully combinational divider is not.

### What these numbers are not

They are HDL Coder's count of operators inferred from the generated code. They
are **not** synthesis results and must not be read as LUT/FF/DSP/BRAM. A
multiplier here may map to one DSP48 slice or to several, and RAM counts do not
translate directly into BRAM.

### What remains blocked, and by what

- **HDL cosimulation** is not run. No HDL simulator is installed; HDL Verifier
  is licensed but has nothing to drive. This is a tooling gap, not a design
  problem.
- **Board-level implementation and measured power** are not available. The FFT
  correlator and ToA block now have core-only OOC place-and-route results and
  vectorless power estimates through boundary-register wrappers. A full design
  still needs board clocking, AXI, package I/O, the processing system, and the
  AD936x interface.

An earlier revision of this section said synthesis was blocked because no
Vivado was installed and only ISE 14.7 was present. That was wrong: Vivado
2021.1 is installed at `<VIVADO_INSTALL_ROOT>`, and the search that
concluded otherwise was mine, not a property of the host. Synthesis results
are in the next section.

## SFD validation and packet framing

The two stages that turn an acquired packet into a routed symbol stream.

### The SFD needs no reference of its own

Dechirping the SFD needs `conj(fft(refDown))`, which looks like a second
pair of ROMs and roughly an extra BRAM at SF7/L=8. It is not needed. With
`refDown = conj(refUp)` and `fft(conj(v))[k] = conj(fft(v)[-k])`,

```text
conj(fft(refDown))[k] = fft(refUp)[-k] = conj( stored[(-k) mod M] )
```

so the downchirp factor is the table the correlator already holds, read at
the complemented address with the imaginary part negated. `M` is a power of
two, so the complement is a mask; both operations are free, and the
transform is its own inverse, so one ROM serves both paths behind a single
mode bit.

Measured before being relied on: derived and directly computed spectra agree
to **4.8e-16 relative** across SF7/SF9 and L=1/4, and downchirp symbols
dechirp to their own bins through the derived table.

### What the SFD is checked against

Also measured rather than assumed. On a realigned grid, for injected offsets
of 0, 1 and 3 bins:

| preamble bin | 0 | 1 | 3 |
|---|---:|---:|---:|
| SFD down bin | 0 | 127 | 125 |

so `downBin = mod(-preambleBin, N)`. Whatever displaces the preamble upward
displaces the SFD downward by the same amount.

This deliberately does **not** split the displacement into CFO and timing.
`lora_phy.joint_timing_cfo_from_bins` already does that, with a sign
convention verified against 130 real packets, and a second convention here
would be a good way to end up with two that disagree.

The check is only valid on a realigned grid: on the free-running grid the
preamble bin also carries the whole-chip offset and the mirror breaks.

### Framing, and why re-arming is the point

The framing FSM routes sync, SFD, header and payload, then returns to idle.
Re-arming matters as much as routing: the front-end realigns once per reset,
so without a stage that knows a packet has ended, the receiver acquires one
packet and then ignores the radio.

Bit-exact against `lora_phy.packet_frame_step`, per symbol:

| Symbols | Packets completed | Rejections | Header symbols | Payload symbols | Mismatches |
|---:|---:|---:|---:|---:|---:|
| 390 | 7 | 15 | 56 | 35 | 0 |

Zero mismatches across all six outputs. The stimulus mixes clean packets,
both rejection paths, back-to-back packets and seeded random events, and the
regression fails if it stops completing packets or stops exercising a
rejection — a framing FSM that parks after one packet passes every
single-packet test, so the test set has to make that impossible.

Header and payload lengths are input ports rather than compile-time
constants. LoRa derives the payload symbol count from the decoded header,
which lives in software behind the documented interface; a second copy of
that arithmetic in the framing path would be a good way to have two that
disagree.

Raw table: [`simulink-m2-framing.csv`](data/simulink-m2-framing.csv).

### The SFD acceptance DUT

The MATLAB rule above became a DUT, checked per group on exact equality.

| SF | N | Groups | Accepted by MATLAB | Decision mismatches |
|---:|---:|---:|---:|---:|
| 7 | 128 | 220 | 10 | 0 |
| 5 | 32 | 220 | 14 | 0 |
| 9 | 512 | 220 | 10 | 0 |

660 groups, zero mismatches on the decision, the self-agreement flag and the
mirror itself. Only 10 to 14 groups of 220 are accepted per configuration,
and that ratio is the point: this stage exists to reject signals that already
passed preamble and sync, so a stimulus it accepted wholesale would prove
nothing. The regression fails if a configuration accepts everything or
nothing.

The set includes the case the stage exists for — two windows that agree with
each other but sit two bins off the mirror. Agreement alone is not evidence;
a run of upchirps agrees with itself too.

The DUT does not dechirp. Because the downchirp reference costs no ROM of
its own, the SFD path reuses the correlator and this block only decides. The
mirror is computed by masking rather than `mod()`, since `N` is a power of
two and `mod()` on a signed value is a division HDL Coder will not generate.

Raw table: [`simulink-m2-sfd.csv`](data/simulink-m2-sfd.csv).

## Synthesis: the first numbers that describe silicon

Vivado 2021.1, `xc7z020clg484-1`, out of context, via `run_synthesis`.
Everything published before this section counted inferred operators; this
section counts primitives.

| Target | LUTs | Registers | BRAM36 | DSP48 | CARRY4 | Fmax |
|---|---:|---:|---:|---:|---:|---:|
| `fft-correlator-fixed` | 13893 | 15122 | 8 | 34 | 1064 | 59.1 MHz |
| `blind-detector` | 2435 | 148 | 0 | 0 | 572 | 548.5 MHz |
| `framing` | 120 | 19 | 0 | 0 | 4 | 192.9 MHz |
| `sfd` | 334 | 20 | 0 | 0 | 74 | 96.7 MHz |
| `acquisition` | 237 | 34 | 0 | 0 | 40 | 80.0 MHz |
| `toa-interpolator` | 744 | 374 | 0 | 0 | 70 | 118.9 MHz |
| `joint-timing-cfo` | 346 | 0 | 0 | 0 | 62 | — |
| `frequency-estimator` | 16 | 34 | 0 | 0 | 4 | 376.9 MHz |

Against the part's 53200 LUTs, 106400 registers, 140 BRAM36 and 220 DSP48, the
correlator occupies **26 % of the LUTs, 14 % of the registers, 5.7 % of the
BRAM and 15 % of the DSPs**. The whole receiver front-end fits with room to
spare, which was not obvious beforehand.

`joint-timing-cfo` has no Fmax because it has no registers at all. It is pure
combinational logic, so there is no register-to-register path to constrain.
That is a property of the block, and it is recorded as absent rather than
converted into a number.

When only carrier frequency is required, removing the timing correction and
registering the boundary reduces the estimator from **346 to 16 LUTs** — 330
fewer, or **95.4 %** — with 34 flip-flops and a fixed two-clock latency. It
uses no DSP or BRAM and has a real derived Fmax of **376.9 MHz**.
The SF7 specialization also narrows the guaranteed `[0, 127]` bin inputs from
the joint block's generic `uint16` interface to `uint8`; SF9–SF12 builds retain
`uint16`.
The comparison is deliberately limited to these estimator blocks; both still
consume peak bins produced elsewhere and neither number includes the FFT
correlator.

The first ToA implementation had the same problem and an avoidable area cost:
a combinational divide synthesized to **1793 LUTs**, zero registers, and no
defined Fmax. The packet-rate implementation now captures one request while
idle, reuses one logarithm unit over three clocks, registers numerator and
denominator, performs one quotient bit per clock for 32 clocks, and saturates
on a final clock. Its model latency is 38 clocks. Synthesis drops to **744
LUTs** (1049 fewer, **58.5 %**) at the cost of **374 registers**, and produces
a real register-to-register estimate of **118.9 MHz**. Accuracy is unchanged;
the numerical comparison remains the 0.382 m maximum and 7.941 m RMS recorded
in [`simulink-m2-toa-interpolator.csv`](data/simulink-m2-toa-interpolator.csv).

### Two things the operator counts got wrong

This is why the earlier tables were labelled as not being synthesis results,
and it is worth showing the size of the gap rather than only warning about it.

**BRAM was overstated eightfold.** HDL Coder reported **64 RAMs** for the
correlator. Synthesis maps them to **8 BRAM36 tiles**. The operator count is a
count of inferred memories, and several of them share a tile or collapse into
distributed RAM.

**The blind detector is not as free as its operator count suggested.** Its
headline was 0 multipliers, 0 RAMs and 168 register bits — about 0.6 % of the
correlator's register bits — and all of that survives synthesis: still 0 DSPs,
still 0 BRAM, 148 registers. But it costs **2435 LUTs, 18 % of the
correlator's LUT count**, because the predicate is a wide comparison tree and
comparisons live in LUTs and CARRY4 chains, which no operator count reports.
"Free in the expensive resources" is the accurate claim; "essentially free"
was not.

DSPs, by contrast, matched exactly: 34 inferred multipliers, 34 DSP48s.

### What Fmax does and does not say

59.1 MHz for the correlator is the synthesis estimate on an unplaced,
unrouted design against a 5 ns probe. It is not the post-route result.

It is nevertheless far above what the application needs. The DUT consumes one
sample per clock, so the requirement is the sample rate: 1 MHz at
BW = 125 kHz with `L = 8`, or 4 MHz at BW = 500 kHz. Even the pessimistic
figure leaves more than an order of magnitude of headroom. The number that
would matter for a faster design is the critical path through the correlator,
and that is where the headroom would be spent.

Raw table: [`simulink-m3-synthesis.csv`](data/simulink-m3-synthesis.csv).

## Post-route timing and vectorless core power

`run_implementation` leaves each generated DUT unchanged and surrounds it with
registered functional inputs and outputs. Vivado 2021.1 then synthesizes,
places, physically optimizes, and routes that wrapper out of context for
`xc7z020clg484-1`. The boundary registers make the DUT's external
combinational paths measurable, but they also mean that the resource counts
below describe wrapper plus core and should not be compared one-for-one with
the bare-DUT synthesis table.

| Target | LUTs | Registers | BRAM36 | DSP48 | Setup WNS | Hold WNS | Post-route Fmax |
|---|---:|---:|---:|---:|---:|---:|---:|
| `fft-correlator-fixed` | 13837 | 15303 | 8 | 34 | -11.590 ns | +0.009 ns | 60.277 MHz |
| `toa-interpolator` | 763 | 507 | 0 | 0 | -2.705 ns | +0.059 ns | 129.786 MHz |

The 5 ns constraint is deliberately a probe rather than the application
requirement. Derived achieved periods are 16.590 ns and 7.705 ns. Against the
maximum required 4 MHz sample clock, the routed estimates leave approximately
**15.1x** headroom for the correlator and **32.4x** for ToA. The correlator's
16.685 ns critical datapath splits into 8.425 ns logic and 8.260 ns routing;
the ToA path is 7.568 ns, split into 1.324 ns logic and 6.244 ns routing.

Power is estimated after routing at 4 MHz with Vivado's vectorless propagation,
12.5 % default primary-input toggle rate, 0.5 static probability, typical
process, and a fixed 25 degC junction assumption:

| Target | Total on-chip | Dynamic | Device static | Confidence |
|---|---:|---:|---:|---|
| `fft-correlator-fixed` | 0.110 W | 0.007 W | 0.102 W | Medium |
| `toa-interpolator` | 0.102 W | <0.001 W | 0.102 W | Medium |

This is a core-only OOC model, not a measurement of board rails. It excludes
the processing system, AD936x interface, AXI, board clocking, package I/O, and
real switching activity. The ToA dynamic field is 0 W in the CSV because it is
below the report's 1 mW resolution, not because the physical dynamic power is
zero.

Raw table: [`simulink-m3-post-route.csv`](data/simulink-m3-post-route.csv).

## Limitations and open items

The remaining limitations are:

1. **No cosimulation or board-level implementation.** Verilog is generated for
   all eight hardware-bound DUTs with zero HDL errors, and all eight pass
   out-of-context synthesis. The FFT correlator and ToA interpolator also have
   OOC post-route timing and vectorless core-power estimates through registered
   boundary wrappers. A complete top level with board clocking, AXI, package
   I/O, the processing system, and AD936x interface still does not exist.
   Cosimulation is not run because no HDL simulator is installed.
2. **Real-signal coverage is one corpus.** 130 packets at SF5/SF6/SF7, all
   `L = 8`, all strong-signal OTA captures. This is not a sensitivity test and
   does not cover SF8–SF12, other `L`, or weak signals.

Deliberately out of scope for M2, with a documented software interface instead:
deinterleaving, Hamming FEC, dewhitening, and CRC. Also out of scope and staying
in software: TDoA association, delay calibration, and 2D multilateration.
