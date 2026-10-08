# Zynq LoRa PHY

[Русская версия документации](README.ru.md)

FPGA/SDR implementation of LoRa communication, precise time-of-arrival (ToA)
estimation, and time-difference-of-arrival (TDoA) positioning.

The project is an engineering and research platform, not a replacement for a
low-power commercial LoRa transceiver. Its purpose is to expose the complete
PHY processing chain, make internal measurements observable, and provide a
repeatable path from a MATLAB floating-point reference model through Simulink
and generated Verilog to a ZynqSDR implementation.

The repository is a self-contained baseline for the standard LoRa / LoRa-like
PHY, SDR acquisition, synchronization, timestamping and positioning; related
waveform-design research builds on it and is maintained separately (see
[scope and boundary](docs/public_private_boundary.md)).

For the smaller generic CSS learning path and readable SF7 baseline RTL, see the
companion [`zynq-sdr-course`](https://github.com/Lay007/zynq-sdr-course). The
[project-boundary ADR](docs/architecture-decisions/0003-course-project-boundary.md)
defines why generated LoRa HDL is not duplicated there.

> Status as of 2026-10-02: the MATLAB → Simulink → generated Verilog →
> cold-bootable ZynqSDR/CLG400 path is implemented. Real over-the-air SX1262
> packets pass explicit-header and payload CRC checks; FPGA SF7/BW125 PER
> curves are published for CR 4/5 through 4/8. M11 fixes correlation-peak
> precision: the measured CR 4/5 PER 10% threshold is about −7.8 dB, versus
> −8.2 dB for the known-timing model
> ([method and results](docs/per-curves-experiment.md)). These are conducted
> measurements at specified SNR, not absolute sensitivity in dBm.
>
> RTL regressions cover accelerated joint ToA/CFO search, real SFD framing,
> consecutive packets without reset, and recovery from zero or missing
> interpolation responses. Bench tools support separately regenerated FPGA
> profiles for SF5–SF12/BW500. The committed DSP core remains SF7/L8: each new
> mode requires regeneration, full-packet RTL checks, routed timing sign-off
> and hardware measurements. Common-time synchronization of two receivers,
> systematic-delay calibration and hardware TDoA positioning remain open.

## Project goals

- Receive and transmit LoRa-compatible packets with a ZynqSDR platform.
- Build a traceable implementation path: MATLAB float → Simulink → generated
  Verilog → ZynqSDR.
- Estimate timing, CFO, SFO, RSSI, and SNR in addition to decoded payloads.
- Timestamp packet arrivals in programmable logic on multiple synchronized
  receivers.
- Measure and calibrate systematic channel delays before solving 2D TDoA.
- Keep experiments reproducible through versioned configurations, captures,
  metrics, and reports.

### Engineering collaboration

This repository also serves as public evidence for focused R&D work in LoRa/CSS
PHY, SDR acquisition, packet timing, ToA/TDoA, MATLAB/Simulink-to-FPGA flows,
and measurement-driven verification. For consulting or project collaboration,
see the [engineering portfolio](https://lay007.github.io/) or
[GitHub profile](https://github.com/Lay007).

Current work measures PER and precise-timestamp availability versus SNR,
extends the FPGA receiver to other SF/BW modes, and compares it with
SX1262/LR1121 on the same signal. CRC-valid reception and usable ToA are
separate outcomes. Single-receiver repeatability does not establish TDoA
accuracy; that requires common time and calibrated receive paths.

## Current contents

- `model/matlab/` — authoritative floating-point CSS/LoRa model and MATLAB unit
  tests.
- `model/simulink/` — executable streaming and fixed-point architecture used as
  the HDL Coder source, with MATLAB-aligned regression and acceptance reports.
- `src/zynq_lora_phy/` — auxiliary independent NumPy checks for CSS, ToA, and
  TDoA; not the golden implementation.
- `tests/` — deterministic unit tests for symbol recovery, impairments, ToA,
  and multilateration.
- `docs/` — architecture, development roadmap, and test-bench requirements.
- `experiments/templates/` — versioned metadata templates for ToA and TDoA
  measurements.
- `fpga/` — generated HDL, portable receiver RTL, CLG400 board overlay, tests,
  and synthesis evidence.
- `firmware/` and `hardware/` — integration boundaries for later PL, PS, and
  board-specific work.

## MATLAB quick start

MATLAB R2025a is currently used for local validation. From the repository root:

```matlab
cd model/matlab
results = run_tests;
assertSuccess(results);
```

Generate the acquisition, uncoded CSS, and coded packet BER/PER figures:

```matlab
outputs = run_visualizations;
addpath examples
figures = redraw_ber_campaign; % README curves from saved counts
```

Inspect RTL-SDR CU8, Pluto/GNU Radio CF32, or CI16/HDL recordings visually.
The Inspector estimates BW, SF, carrier offset, symbol duration, SNR, and
dechirped FFT bins, identifies compatible Semtech LoRa radio profiles, and for
properly named HDL CI16 captures compares the waveform against the MATLAB
golden reference using EVM, correlation, and phase-error metrics:

```matlab
addpath apps
app = lora_phy_inspector;
```

![LoRa PHY Inspector on a real over-the-air SX1262 capture](docs/images/lora-phy-inspector-ota-sx1262.png)

*The real Inspector window, exported from the application, on an over-the-air
capture: a Heltec WiFi LoRa 32 V4.3 (SX1262) transmitting SF7 / BW 125 kHz at
868.1 MHz, received by ZynqSDR/AD9361 at 1 MS/s tuned to 868.35 MHz
([`sf7-bw125.cf32`](captures/reference/2026-08-03-heltec-v43-zynqsdr-mode-sweep/)).
It reports SF7, a measured bandwidth of 125.0 kHz, a carrier at 868.100801 MHz
(CFO +800.7 Hz against the nominal transmitter frequency) and 55.7 dB SNR from
the no-signal intervals. The weaker band near +250 kHz, about 30 dB down and
time-aligned with the bursts, is consistent with the receiver's I/Q mirror
image.*

See the **[LoRa PHY Inspector guide](docs/lora-phy-inspector.md)** for input
formats, golden-verification thresholds, radio-profile matching, interpretation,
methodology, and current limits.

With a serial-controlled transmitter and PlutoSDR or RTL-SDR connected to the
same computer, the complete transmit → record → analyze sequence can be run by
[`tools/run_phy_experiment.py`](tools/run_phy_experiment.py). Start with a
hardware-free `--dry-run`; the full workflow is documented in
[One-machine transmit, capture, and analysis](docs/automated-phy-experiment.md).

The symbol-demodulation view shows how different cyclic shifts become distinct
dechirped tones and FFT peaks:

![CSS symbol demodulation](docs/images/css-symbol-demodulation-sf7.png)

The acquisition receiver detects a research `8 upchirp + 2 downchirp`
preamble, estimates CFO, and recovers aligned payload symbols. It is an
algorithm-development frame. Separately, `encode_packet` and `decode_packet`
implement explicit header, payload CRC, whitening, Hamming FEC, diagonal
interleaving, and Gray/CSS mapping with all intermediate values exposed.

![CSS frame acquisition](docs/images/css-frame-acquisition-sf7.png)

![Current CSS demodulator versus coherent reference](docs/images/css-ber-current-vs-ideal.png)

![Coded LoRa BER and PER for SF5 through SF7](docs/images/lora-coded-ber-sf5-sf7-fft-correlator.png)

Lines connect only positive observed BER/PER. Unconnected downward triangles
show the **two-sided 95% Wilson upper bound for a zero-error run**, not a
positive observed error probability. The uncoded campaign uses 4,000 symbols
per point; the coded campaign uses 200 packets with 16-byte payloads. Counts
and intervals remain in the [source CSVs](docs/ber-methodology.md).

Hardware FPGA SF7/BW125 PER curves for CR 4/5 through 4/8 and model comparisons
are in the [bench report](docs/per-curves-experiment.md). The
[finite-series protocol](docs/finite-per-bench.md) accounts for every planned
transmission, including leading/trailing losses, and checks ToA separately.
[Joint-search latency](docs/joint-search-latency.md) is reported with its
scope: RTL timing does not establish total hardware processing latency.

## What the BER figure means

The uncoded curves are a **demodulator baseline**, not coded LoRa packet BER.
They compare the legacy single-phase and polyphase receivers, the HDL-oriented
FFT correlator, and an independent exact matched filter for 1, 2, 4, and 8
samples/chip. The FFT correlator closes the former 5–6 dB `L=8` AWGN gap.
Preamble failures, whitening, FEC, interleaving, CRC, and rejected packets are
excluded from these uncoded curves.

The coded campaign compares hard and soft decoding for SF5, SF6, and SF7 at
CR 4/5, 8 samples/chip, and a 16-byte payload. It reports pre-FEC BER, hard and
soft payload BER/PER, soft recoveries, raw counts, and 95% Wilson intervals.
Known packet timing still excludes preamble-detection failures. Measurement
definitions, SNR convention, trial counts, zero-error marker rule, and data are in the
**[BER/SER methodology](docs/ber-methodology.md)**. The implemented coding chain is
described in **[LoRa PHY coding stages](docs/lora-phy-coding.md)**.

The acquisition-inclusive M1 campaign processes continuous IQ, covers all 32
SF5...SF12 and CR 4/5...4/8 pairs, exercises RF/front-end impairments, and
publishes calibrated 2D TDoA Monte Carlo results. See the
**[MATLAB M1 acceptance report](docs/matlab-m1-acceptance.md)**.

## Simulink quick start

Models are generated by script and never committed, so building one is the
normal way to get it:

```matlab
cd model/simulink
report = report_toolchain;                  % verify products and licenses
info = build_fft_correlator_model;          % SF7, L=8, double
results = run_simulink_regression;          % toolchain, double, joint sync
```

From a shell, the regression returns a nonzero exit code on any MATLAB/Simulink
mismatch:

```bash
matlab -batch "cd model/simulink; run_simulink_regression"
```

Measured results and selected fixed-point formats that establish M2 acceptance
are in [M2 acceptance](docs/simulink-m2-acceptance.md).

With Vivado available, the generated cores can be measured and packaged:

```matlab
report = run_synthesis;                     % out-of-context resources and Fmax
report = run_ip_packaging;                  % self-contained Vivado IP per core
```

`run_ip_packaging` writes `fpga/build/ip/<target>`, then re-reads each result
from a clean project and instantiates it from the rebuilt catalog, so an IP
that cannot be used fails the target. See
[M3 IP packaging evidence](docs/data/simulink-m3-ip-packaging.csv).

## Auxiliary Python checks

Python 3.10 or newer is recommended.

```bash
python -m venv .venv
python -m pip install -e ".[dev]"
pytest
python examples/css_roundtrip.py
```

The example generates deterministic CSS symbols, applies AWGN and carrier
frequency offset, compensates the known offset, and demodulates the symbols.

## Repository layout

```text
.
├── docs/                   Architecture, roadmap, and bench requirements
├── model/
│   ├── matlab/             Authoritative floating-point model and tests
│   └── simulink/           HDL-oriented executable architecture
├── examples/               Auxiliary Python examples
├── experiments/
│   └── templates/          PHY capture and ToA/TDoA metadata
├── captures/               Local captures plus curated Git LFS references
├── tools/                  Hardware capture helpers
├── fpga/                   PL/RTL sources, constraints, and verification
├── firmware/               Zynq PS software and host control
├── hardware/               Board notes, clocking, and calibration data
├── src/zynq_lora_phy/      Auxiliary Python reference package
└── tests/                  Auxiliary Python tests
```

## Architecture and plan

- [System architecture](docs/architecture.md)
- [Development guide](docs/development.md)
- [Repository scope and boundary](docs/public_private_boundary.md)
- [Roadmap and acceptance criteria](docs/roadmap.md)
- [MATLAB M1 floating-point acceptance](docs/matlab-m1-acceptance.md)
- [Hardware test bench](docs/test-bench.md)
- [RTL-SDR and PlutoSDR packet-capture guide](docs/iq-capture-guide.md)
- [Experiment workflow](experiments/README.md)
- [Heltec V4.3/SX1262 to ZynqSDR hardware sweep](docs/hardware-sweep-2026-08-03-heltec-v43.md)
- **[Stage-by-stage receive-chain differential](docs/stage-differential.md)**
- **[BER/SER methodology](docs/ber-methodology.md)**
- **[Whitening, FEC, interleaving, and CRC](docs/lora-phy-coding.md)**
- [Documentation index](docs/README.md)

## Measurement principles

1. Define and validate algorithms in the MATLAB float model.
2. Compare MATLAB, Simulink, generated Verilog, and hardware with identical test
   vectors.
3. Generate precise timestamps in PL, never from Linux or network arrival time.
4. Treat cable, splitter, RF, ADC, and DSP delays as calibrated quantities.
5. Record configuration and provenance with every result.

## Contributing

Keep changes small and measurable. New DSP blocks should include a reference
model, deterministic tests, numerical tolerances, and a documented hardware
mapping. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
Contributions are accepted under the same license.
